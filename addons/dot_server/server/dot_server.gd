@tool
class_name GSServer
extends "res://addons/dot_server/server/dot_server_tick.gd"

## The dedicated server: place one in a scene and it boots. Owns the listener, sessions, signon,
## tick budget and subsystems, each reached through a [GSNodeRef]. Boot order is fixed, ending
## with the listener, then autoexec and +commands; registers as [code]dot_server[/code].

func _ready() -> void:
	if Engine.is_editor_hint():
		return

	if auto_boot:
		await boot()


## Brings the server up. Idempotent.
func boot() -> GSResult:
	if state != State.IDLE and state != State.STOPPED:
		return GSResult.fail(
			GSError.CODE_STATE, "The server is already running."
		)

	_set_state(State.BOOTING)
	var configured := _load_boot_config()
	if not configured.ok:
		return _boot_failed(configured)

	GSRegistry.register(SERVICE, self)

	_resolve_log_sink()

	GSLog.info(
		CHANNEL,
		"booting",
		{
			"hostname": config.hostname,
			"port": config.port,
			"slots": config.max_players,
			"tickrate": config.tickrate,
		}
	)

	_resolve_console()
	_register_cvars()
	_register_commands()
	_watch_replicated_cvars()

	# server.cfg runs before the listener so FLAG_STARTUP_ONLY cvars are still
	# settable — that is the whole reason for the ordering.
	console.exec_config(config.startup_config, null, false)

	# The command line's CVAR half runs here too: `+sv_tickrate` is startup-only. The
	# `+command` half waits for the listener, below.
	console.execute_command_line(true)

	_apply_cvars_to_config()

	# Awaited: loading bans may hit a remote store, and the listener must not open
	# before the ban list is in force — a window where banned players can connect is
	# small but entirely avoidable.
	await _resolve_subsystems()

	_connect_limiter = GSRateLimiter.new(2.0, 10.0)

	# Built here rather than in _register_cvars so it reads the value server.cfg and
	# the command line actually settled on, not the exported default.
	address_guard = GSAddressGuard.new(config.max_connections_per_ip)
	address_guard.exempt_addresses = config.connection_limit_exempt_addresses

	var listening := _start_listening()
	if not listening.ok:
		return _boot_failed(listening)

	console.set_server_running(true)
	_started_at = int(Time.get_unix_time_from_system())

	console.exec_config(config.autoexec_config, null, false)
	console.execute_command_line()

	_set_state(State.RUNNING)
	_apply_tickrate()

	# Last, and deliberately: a query listener advertises this server to the
	# outside, and there is nothing worth advertising until everything above has
	# come up.
	_open_query_host()

	# Hibernate from the moment the server is up, so the first player's wake resets the map clocks.
	_maybe_hibernate()

	_log_ready()

	if events != null:
		events.fire("server_start", {"hostname": config.hostname})

	return GSResult.success(self)


func _load_boot_config() -> GSResult:
	if config == null:
		config = GSServerConfig.new()

	if config_file != "":
		var loaded := config.apply_json_file(config_file)
		if not loaded.ok:
			return loaded

	config.apply_env()
	config.apply_cli()

	var valid := config.validate()
	if not valid.ok:
		return valid

	config.warn_about_risky_settings()
	return GSResult.success()


func _log_ready() -> void:
	GSLog.info(
		CHANNEL,
		"ready",
		{
			"transport": _transport._transport_name(),
			"web_clients": _transport.supports_web_clients(),
			"enet_udp": enet_port(),
			"rcon": rcon != null and rcon.is_listening(),
			"query": query != null and bool(query.call("is_listening")),
			"a2s": a2s != null,
			"admins": admins.admin_count() if admins != null else 0,
			"bans": bans.count() if bans != null else 0,
		}
	)


func _boot_failed(res: GSResult) -> GSResult:
	_set_state(State.STOPPED)
	GSLog.fatal(
		CHANNEL,
		"boot failed: %s" % res.error.message,
		{"detail": res.error.detail}
	)
	return res


## Shuts down cleanly: tells clients, reports offline, flushes logs.
func shutdown(reason: String = "Server shutting down") -> void:
	if state == State.SHUTTING_DOWN or state == State.STOPPED:
		return

	_set_state(State.SHUTTING_DOWN)
	GSLog.info(CHANNEL, "shutting down", {"reason": reason})

	if events != null:
		events.fire("server_shutdown", {"reason": reason})

	# Tell everyone before closing the socket. A client that is told why it was
	# disconnected shows a message; one whose socket just closes shows "connection
	# lost", which players report as a crash.
	for session in sessions():
		_notify_disconnect(session, reason)

	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null

	_peer = null
	_sessions.clear()
	_by_userid.clear()

	if bans != null:
		bans.save_bans()

	_set_state(State.STOPPED)
	GSRegistry.unregister_instance(SERVICE, self)

	# Last, and after the final state change, so the shutdown itself is in the file.
	# Records still sitting in a buffer when the process goes are the ones that would
	# have explained why it went.
	flush_log()


## Writes out whatever the log destination is holding. Call on shutdown or before anything
## risky; a remote destination is started, not waited for (dot-log's [code]shutdown()[/code] waits).
func flush_log() -> void:
	if log_node == null or not is_instance_valid(log_node):
		return
	if log_node.has_method("flush_all"):
		log_node.call("flush_all")
	elif log_node.has_method("flush"):
		log_node.call("flush")


func _exit_tree() -> void:
	if state == State.RUNNING or state == State.HIBERNATING:
		shutdown("Server stopped")


func _resolve_console() -> void:
	if console_ref == null:
		console_ref = GSNodeRef.of_created(&"Console", GSConsole)
	console = _resolve(console_ref, "console") as GSConsole


## Applies the configured levels, then attaches or creates somewhere for the log to go. Runs
## before the first line this boot emits, so the levels apply to the interesting part.
func _resolve_log_sink() -> void:
	_apply_log_levels()

	if log_sink_ref != null:
		log_node = log_sink_ref.resolve_or_null(self, CHANNEL)

	if log_node == null and config.log_file_enabled:
		log_node = _create_log_sink()

	if log_node == null:
		return

	# A router is anything that can be asked what it is doing and told to flush — which
	# is GameSpice Log's, and could be somebody else's. Probed rather than named: naming it
	# would make an optional addon a hard dependency of every server in the family.
	log_is_router = (
		log_node.has_method("describe_lines") and log_node.has_method("flush_all")
	)

	if log_is_router and log_node.has_method("set_tag"):
		# The tags a collector needs to tell four servers apart. Set here rather than by
		# the host because the server is the only thing that knows them.
		log_node.call("set_tag", "hostname", config.hostname)
		log_node.call("set_tag", "port", config.port)

	GSLog.debug(
		CHANNEL,
		"log destination attached",
		{"node": log_node.name, "router": log_is_router}
	)


func _apply_log_levels() -> void:
	var level: int = GSServerConfig.parse_log_level(config.log_level)
	if level >= 0:
		GSLog.set_level(level)

	var mirror: int = GSServerConfig.parse_log_level(config.log_mirror_min_level)
	if mirror >= 0:
		GSLog.mirror_min_level = mirror

	for entry in config.log_channel_levels:
		var parts: PackedStringArray = String(entry).split("=", false, 1)
		if parts.size() != 2:
			continue
		var parsed: int = GSServerConfig.parse_log_level(parts[1])
		if parsed >= 0:
			GSLog.set_channel_level(parts[0].strip_edges(), parsed)


## The plain file sink every server gets when nothing better was placed.
func _create_log_sink() -> Node:
	var sink := GSLogSink.new()
	sink.name = "LogSink"
	sink.directory = config.log_directory
	sink.basename = config.log_basename
	sink.json_lines = config.log_json
	sink.max_file_bytes = config.log_max_file_bytes
	sink.max_files = config.log_max_files
	# The file keeps whatever GSLog itself let through: a second threshold here would
	# mean an operator who raised the level still found nothing in the file, with two
	# places to look before working out why.
	sink.level = GSLog.Level.TRACE
	add_child(sink)
	return sink


func _resolve_subsystems() -> void:
	if events_ref == null:
		events_ref = GSNodeRef.of_created(&"Events", GSEventBus)
	events = _resolve(events_ref, "events") as GSEventBus

	await _resolve_moderation()
	_resolve_game_subsystems()
	_resolve_operator_io()


func _resolve_moderation() -> void:
	if audit_ref == null:
		audit_ref = GSNodeRef.of_created(&"Audit", GSAuditLog)
	audit = _resolve(audit_ref, "audit") as GSAuditLog
	if audit != null:
		audit.config = config
		# Opened here, not in its `_ready`: a created node has already run `_ready` before this
		# assigns the config, so the log would resolve no path and record nothing. Same reason
		# `admins.load_admins()` is explicit below.
		audit.open_log()

		if not audit.is_recording():
			GSLog.warn(
				CHANNEL,
				"no audit log; administrative actions will not be recorded",
				{"setting": "audit_log_path"}
			)

	if admin_ref == null:
		admin_ref = GSNodeRef.of_created(&"Admins", GSAdminManager)
	admins = _resolve(admin_ref, "admins") as GSAdminManager
	if admins != null:
		admins.config = config
		# Created nodes have already run _ready() by the time we set config, so the
		# load is triggered explicitly rather than relying on _ready ordering.
		admins.load_admins()
		_attach_auth_admin_source()

	if bans_ref == null:
		bans_ref = GSNodeRef.of_created(&"Bans", GSBanManager)
	bans = _resolve(bans_ref, "bans") as GSBanManager
	if bans != null:
		bans.config = config
		bans.audit = audit
		await bans.load_bans()
	watch_ban_source()


func _resolve_game_subsystems() -> void:
	if chat_ref == null:
		chat_ref = GSNodeRef.of_created(&"Chat", GSChatManager)
	chat = _resolve(chat_ref, "chat") as GSChatManager
	if chat != null:
		chat.setup(self)

	if games_ref == null:
		games_ref = GSNodeRef.of_created(&"Games", GSGameManager)
	games = _resolve(games_ref, "games") as GSGameManager
	if games != null:
		games.setup(self)
		# Awake while a game loads: a game reads its tick rate as it starts, and a hibernated
		# engine (hibernate_tickrate) made a delivered game's netcode refuse to start. Back to
		# sleep after the load, deferred, so a host's game_loaded handler runs awake.
		game_changing.connect(func(_from: String, _to: String) -> void: _begin_game_load())
		games.game_loaded.connect(func(_key: String) -> void: _end_game_load())
		games.game_load_failed.connect(func(_key: String, _error: GSError) -> void: _end_game_load())

	if votes_ref == null:
		votes_ref = GSNodeRef.of_created(&"Votes", GSVoteManager)
	votes = _resolve(votes_ref, "votes") as GSVoteManager
	if votes != null:
		votes.setup(self)

	if modules_ref == null:
		modules_ref = GSNodeRef.of_created(&"Modules", GSModuleHost)
	modules = _resolve(modules_ref, "modules") as GSModuleHost
	if modules != null:
		modules.setup(self)


func _resolve_operator_io() -> void:
	if config.rcon_password != "":
		if rcon_ref == null:
			rcon_ref = GSNodeRef.of_created(&"Rcon", GSRconServer)
		rcon = _resolve(rcon_ref, "rcon") as GSRconServer
		if rcon != null:
			rcon.setup(self)
	else:
		GSLog.info(
			CHANNEL, "RCON is disabled (no rcon_password set)"
		)

	# Built unconditionally: it does nothing when there is no terminal (unit file, container
	# without `-i`, CI). `stdin_console_enabled` is for a server whose stdin carries something
	# that is not commands.
	if config.stdin_console_enabled:
		if stdin_ref == null:
			stdin_ref = GSNodeRef.of_created(&"StdinConsole", GSStdinConsole)
		stdin_console = _resolve(stdin_ref, "stdin_console") as GSStdinConsole
		if stdin_console != null:
			stdin_console.read_pipes = config.stdin_console_pipes
			var reading := stdin_console.setup(self)
			if not reading.ok:
				GSLog.warn(CHANNEL, "the stdin console did not start", {
					"error": str(reading.error)
				})

	# Record permission-carrying commands in the audit trail. Done here rather than
	# in the console so the console stays independent of moderation.
	if audit != null and console != null:
		console.command_executed.connect(_on_command_for_audit)


func _resolve(ref: GSNodeRef, what: String) -> Node:
	var res := ref.resolve(self)
	if not res.ok:
		GSLog.error(
			CHANNEL,
			"could not resolve the %s node" % what,
			{"ref": ref.describe(), "detail": res.error.message}
		)
		return null
	return res.value


## Attaches GameSpice Auth's admin source when present, found through [GSRegistry] so GameSpice Server
## has no dependency on GameSpice Auth.
func _attach_auth_admin_source() -> void:
	var auth := GSRegistry.get_service(&"dot_auth_server")
	if auth == null:
		return

	var source_class := "GSAuthAdminSource"
	if not ClassDB.class_exists(source_class) and not _script_class_exists(source_class):
		return

	GSLog.debug(
		CHANNEL,
		"dot-auth is present; attach a GSAuthAdminSource to map site groups "
		+ "to server permissions"
	)


static func _script_class_exists(name: String) -> bool:
	for entry in ProjectSettings.get_global_class_list():
		if str(entry.get("class")) == name:
			return true
	return false


func _on_command_for_audit(ctx: GSCmdContext) -> void:
	var cmd := console.find_command(ctx.command)
	if cmd != null:
		audit.record_command(ctx, cmd.permission)


func _start_listening() -> GSResult:
	_transport = config.resolve_transport()

	var created := _transport.create_server(config.port, config.bind_address)
	if not created.ok:
		return created.wrap("Could not start listening.")

	_peer = created.value
	multiplayer.multiplayer_peer = _peer

	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)

	if not _transport.supports_web_clients():
		GSLog.warn(
			CHANNEL,
			"this transport cannot accept browser clients — set "
			+ "require_web_clients on GSTransportAuto if you need them",
			{"transport": _transport._transport_name()}
		)

	return GSResult.success(_peer)


func _make_envelope() -> GSEnvelope:
	var env := GSEnvelope.new()
	env.register_core()
	env.handle(GSEnvelope.CREDENTIALS, _on_credentials)
	env.handle(GSEnvelope.CONTENT_PROGRESS, _on_content_progress)
	env.handle(GSEnvelope.CONTENT_READY, _on_content_ready)
	env.handle(GSEnvelope.LOADED, _on_loaded)
	env.handle(GSEnvelope.HEARTBEAT, _on_heartbeat)
	env.handle(GSEnvelope.PING, _on_ping)
	env.handle(GSEnvelope.VISIBILITY, _on_visibility)
	env.handle(GSEnvelope.CHAT_SUBMIT, _on_chat_submit)
	env.handle(GSEnvelope.SCOREBOARD_WANT, _on_scoreboard_want)
	return env


## Contract in dot_server_wire.gd; the lanes are the three `_dot_down` RPCs below.
func send_kind(
	peer_id: int,
	kind: StringName,
	payload: Dictionary = {},
	lane: GSEnvelope.Lane = GSEnvelope.Lane.CONTROL
) -> bool:
	if peer_id <= 0 or multiplayer == null or multiplayer.multiplayer_peer == null:
		return false
	if not envelope.should_send(peer_id, kind):
		return false

	match lane:
		GSEnvelope.Lane.UNRELIABLE:
			_dot_down_unreliable.rpc_id(peer_id, String(kind), payload)
		GSEnvelope.Lane.EVENT:
			_dot_down_event.rpc_id(peer_id, String(kind), payload)
		_:
			_dot_down.rpc_id(peer_id, String(kind), payload)
	return true


## The six RPCs, and the only six this node will ever declare: three server to client
## (`_dot_down`), three client to server (`_dot_up`). Their names are what [GSSignon] hashes;
## a seventh breaks every shipped client, so add a kind to [member envelope] instead.
@rpc("authority", "reliable", "call_remote", CHANNEL_CONTROL)
func _dot_down(_kind: Variant, _payload: Variant) -> void:
	pass


@rpc("authority", "unreliable", "call_remote", CHANNEL_CONTROL)
func _dot_down_unreliable(_kind: Variant, _payload: Variant) -> void:
	pass


@rpc("authority", "reliable", "call_remote", CHANNEL_EVENT)
func _dot_down_event(_kind: Variant, _payload: Variant) -> void:
	pass


@rpc("any_peer", "reliable", "call_remote", CHANNEL_CONTROL)
func _dot_up(kind: Variant, payload: Variant) -> void:
	envelope.dispatch(multiplayer.get_remote_sender_id(), kind, payload)


@rpc("any_peer", "unreliable", "call_remote", CHANNEL_CONTROL)
func _dot_up_unreliable(kind: Variant, payload: Variant) -> void:
	envelope.dispatch(multiplayer.get_remote_sender_id(), kind, payload)


@rpc("any_peer", "reliable", "call_remote", CHANNEL_EVENT)
func _dot_up_event(kind: Variant, payload: Variant) -> void:
	envelope.dispatch(multiplayer.get_remote_sender_id(), kind, payload)
