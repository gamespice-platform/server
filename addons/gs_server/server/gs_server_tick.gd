@tool
extends "res://addons/gs_server/server/gs_server_sessions.gd"

## The tick, timeout sweep and cvar registration of [GSServer].

func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if state != State.RUNNING and state != State.HIBERNATING:
		return

	# Exponential averages rather than a window: two floats, and a heartbeat every two
	# seconds reads them. The 0.05 is about the last twenty frames.
	var ms := delta * 1000.0
	if _frame_ms <= 0.0:
		_frame_ms = ms
	_frame_dev_ms = lerpf(_frame_dev_ms, absf(ms - _frame_ms), 0.05)
	_frame_ms = lerpf(_frame_ms, ms, 0.05)

	_sweep_accum += delta
	if _sweep_accum >= 1.0:
		_sweep_accum = 0.0
		_sweep_timeouts()

	_scoreboard_accum += delta
	if _scoreboard_accum >= scoreboard_interval_sec:
		_scoreboard_accum = 0.0
		_send_scoreboards()


## Drops clients that have been stuck in a stage too long.
##
## Per-stage timeouts: a 400 MB download and an auth reply differ by three orders of magnitude.
func _sweep_timeouts() -> void:
	for session in sessions():
		# A bot sends no packets and finishes no handshake, so every timeout here would
		# fire on one. The host that adopted it decides when it leaves.
		if session.local:
			continue

		var limit := 0.0

		match session.state:
			GSClientSession.State.CONNECTING, GSClientSession.State.AUTHENTICATING:
				limit = config.auth_timeout_sec
				if (
					session.state == GSClientSession.State.AUTHENTICATING
					and not session.credentials_seen
					and session.challenges_sent <= CHALLENGE_RETRIES
					and session.time_in_state() >= CHALLENGE_RETRY_SEC * session.challenges_sent
				):
					_resend_challenge(session)
			GSClientSession.State.PROFILE:
				limit = config.profile_timeout_sec
			GSClientSession.State.DOWNLOADING:
				limit = config.download_timeout_sec
			GSClientSession.State.LOADING:
				limit = config.load_timeout_sec
			GSClientSession.State.SPAWNED:
				# Spawned clients are judged on silence, not on time in state, except one that announced it
				# was about to go silent (a hidden browser tab runs no frames). The grace is the server's
				# number, clamped on arrival, never the client's.
				if session.idle_seconds() > silence_budget(session):
					kick(
						session,
						"Timed out in the background"
						if session.backgrounded
						else "Timed out"
					)
				continue
			_:
				continue

		if limit > 0.0 and session.time_in_state() > limit:
			GSLog.info(
				CHANNEL,
				"timed out during join",
				{
					"user": session.label(),
					"state": session.state_name(),
					"seconds": int(session.time_in_state()),
					# Who a player stuck in PROFILE was waiting on; empty otherwise.
					"held_by": ", ".join(session.profile_holds),
				}
			)
			# PROFILE is a noun, not something a player is doing; the others read as a
			# sentence already ("Timed out while downloading").
			var stage := (
				"setting up a profile"
				if session.state == GSClientSession.State.PROFILE
				else session.state_name().to_lower()
			)
			kick(session, " ".join(["Timed out while", stage]))


func _register_cvars() -> void:
	console.cheats_cvar = console.cvar(
		"sv_cheats",
		"0",
		"Allow cheat-flagged variables to be changed.",
		GSConVar.FLAG_NOTIFY | GSConVar.FLAG_REPLICATED
	)
	_cv_cheats = console.cheats_cvar

	_cv_hostname = console.cvar(
		"hostname",
		config.hostname,
		"Server name shown in listings.",
		GSConVar.FLAG_ARCHIVE | GSConVar.FLAG_NOTIFY
	)

	_cv_password = console.cvar(
		"sv_password",
		config.password,
		"Password required to join. Empty for none.",
		GSConVar.FLAG_PROTECTED | GSConVar.FLAG_ARCHIVE
	)

	_register_admission_cvars()
	_register_limit_cvars()

	# Bound onto the console rather than read here: the console is what applies it, on
	# every line, and a console with no server (an editor, a test) still answers from its
	# own exported default.
	console.chat_commands_cvar = console.cvar(
		"sv_chat_commands",
		"1" if config.chat_commands_open else "0",
		"Let a prefixed chat message run any command the speaker has the flag for.",
		GSConVar.FLAG_ARCHIVE | GSConVar.FLAG_NOTIFY
	)

	console.cvar("sv_lan", "0", "LAN mode: skip listing and heartbeat.", GSConVar.FLAG_ARCHIVE)
	Cvars.register_query(self)

	# Applying the cvar to the live config keeps the two views from drifting: a
	# reader of config.max_players must not see a stale value after an admin
	# changed sv_maxplayers.
	_cv_maxplayers.changed.connect(
		func(_old: String, value: String) -> void:
			config.max_players = value.to_int()
	)
	_cv_hostname.changed.connect(
		func(_old: String, value: String) -> void:
			config.hostname = value
	)
	_cv_timeout.changed.connect(
		func(_old: String, value: String) -> void:
			config.client_timeout_sec = value.to_float()
	)
	_cv_background_grace.changed.connect(
		func(_old: String, value: String) -> void:
			config.background_grace_max_sec = value.to_float()
	)

	# Live rather than startup-only: hibernating is a state the server moves in and out of
	# all day, and an operator switching it off wants the empty server's clock running now,
	# not after a restart.
	console.cvar(
		"sv_hibernate_when_empty",
		"1" if config.hibernate_when_empty else "0",
		"Idle at a reduced tickrate while nobody is connected; the map's clocks wait, and restart when somebody joins. 0 keeps an empty server running, and its map changes on its own.",
		GSConVar.FLAG_ARCHIVE | GSConVar.FLAG_NOTIFY
	).changed.connect(
		func(_old: String, value: String) -> void:
			if state == State.RUNNING or state == State.HIBERNATING:
				_apply_hibernate_setting(value.to_int() != 0)
			else:
				config.hibernate_when_empty = value.to_int() != 0
	)
	Cvars.register_threads(self)


func _register_admission_cvars() -> void:
	# Which kinds of client may join, all on by default (cross-play is the platform's default;
	# these are an owner's opt-out). REPLICATED so a listing can say which are open.
	_cv_single_seat = console.cvar(
		"sv_single_seat", "1",
		"One connection per account: signing in again replaces the older connection.",
		GSConVar.FLAG_ARCHIVE | GSConVar.FLAG_NOTIFY
	)

	_cv_allow_web = console.cvar(
		"sv_allow_web", "1",
		"Admit players in a web browser.",
		GSConVar.FLAG_ARCHIVE | GSConVar.FLAG_NOTIFY | GSConVar.FLAG_REPLICATED
	)
	_cv_allow_desktop = console.cvar(
		"sv_allow_desktop", "1",
		"Admit players on the desktop client (Windows, macOS, Linux).",
		GSConVar.FLAG_ARCHIVE | GSConVar.FLAG_NOTIFY | GSConVar.FLAG_REPLICATED
	)
	_cv_allow_mobile = console.cvar(
		"sv_allow_mobile", "1",
		"Admit players on a phone or tablet.",
		GSConVar.FLAG_ARCHIVE | GSConVar.FLAG_NOTIFY | GSConVar.FLAG_REPLICATED
	)


func _register_limit_cvars() -> void:
	_cv_maxplayers = console.cvar(
		"sv_maxplayers",
		str(config.max_players),
		"Player slots; 0 is unlimited. At most 4095 (refused above): ENet's peer ids are 12 bits.",
		GSConVar.FLAG_ARCHIVE
	).with_range(0, 4095)

	# Live, applied at a boundary. Before the listener it applies at once (server.cfg and
	# `+sv_tickrate` are unchanged); after it the value waits for the game's next boundary,
	# see [method apply_pending_tickrate].
	_cv_tickrate = console.cvar(
		"sv_tickrate",
		str(config.tickrate),
		"Server ticks per second. Set while running, it applies at the next map change.",
		GSConVar.FLAG_ARCHIVE | GSConVar.FLAG_NOTIFY
	).with_min(10)
	_cv_tickrate.changed.connect(
		func(_old: String, value: String) -> void:
			var rate := value.to_int()
			if state != State.RUNNING and state != State.HIBERNATING:
				config.tickrate = rate
				return
			_pending_tickrate = rate if rate != config.tickrate else -1
			if _pending_tickrate > 0:
				GSLog.info(CHANNEL, "tickrate change waiting for the next map change",
					{"now": config.tickrate, "next": rate})
				tickrate_pending.emit(rate)
	)

	# Off by default. See GSTickTiers for the grammar; the slot count picks the rate at start,
	# the players present pick it at each game change.
	console.cvar(
		"sv_tickrate_tiers", "",
		"Tick rate by player count, e.g. players<=32:66,<=64:33,else:22. Empty is off; overrides sv_tickrate.",
		GSConVar.FLAG_ARCHIVE
	)

	_cv_timeout = console.cvar(
		"sv_timeout",
		str(config.client_timeout_sec),
		"Seconds of silence before a client is dropped.",
		GSConVar.FLAG_ARCHIVE
	).with_min(5)

	_cv_background_grace = console.cvar(
		"sv_background_grace",
		str(config.background_grace_max_sec),
		"Seconds of silence allowed a client that says its tab is hidden. 0 refuses.",
		GSConVar.FLAG_ARCHIVE
	).with_min(0)

	_register_wire_limit_cvars()


func _register_wire_limit_cvars() -> void:
	console.cvar(
		"sv_max_name_length", "32",
		"Longest display name a client may sign on with, in characters. 0 = no limit. A longer name is refused (the client keeps its default name, and the server logs why).",
		GSConVar.FLAG_ARCHIVE
	).with_min(0)
	console.cvar(
		"sv_scoreboard_page_bytes", str(SCOREBOARD_PAGE_BYTES),
		"Bytes of one scoreboard page; keep under the datagram size (1392).",
		GSConVar.FLAG_ARCHIVE
	).with_range(256, SCOREBOARD_PAGE_MAX)
	console.cvar(
		"sv_scoreboard_max_bytes", str(SCOREBOARD_MAX_BYTES),
		"Bytes of the single-message board sent to clients that cannot reassemble pages; 0 = unlimited.",
		GSConVar.FLAG_ARCHIVE
	).with_min(0)
	console.cvar(
		"sv_scoreboard_max_rows", str(SCOREBOARD_MAX_ROWS),
		"Most player rows one scoreboard carries (the viewer's own row always goes); 0 = unlimited.",
		GSConVar.FLAG_ARCHIVE
	).with_min(0)
	console.cvar(
		"sv_max_ping_report", str(MAX_PING_REPORT),
		"Largest round-trip time (ms) a client may report; a larger or negative report is refused; 0 = unlimited.",
		GSConVar.FLAG_ARCHIVE
	).with_min(0)
	console.cvar(
		"sv_envelope_max_kinds", str(GSEnvelope.MAX_KINDS),
		"Most kinds one peer advert may carry; a longer advert is refused; 0 = unlimited.",
		GSConVar.FLAG_ARCHIVE
	).with_min(0)
	console.cvar(
		"sv_envelope_max_kind_bytes", str(GSEnvelope.MAX_KIND_BYTES),
		"Longest kind name (bytes) accepted off the wire; a longer one is skipped with an error; 0 = unlimited.",
		GSConVar.FLAG_ARCHIVE
	).with_min(0)
	console.cvar(
		"sv_rcon_max_packet_bytes", str(GSRconServer.MAX_PACKET_BYTES),
		"Largest RCON packet accepted (bytes); a larger one drops the client; 0 = unlimited.",
		GSConVar.FLAG_ARCHIVE
	).with_min(0)
	console.cvar(
		"sv_rcon_max_response_bytes", str(GSRconServer.MAX_RESPONSE_BYTES),
		"Largest RCON response body per packet (bytes); longer output is split at line boundaries; 0 = never split.",
		GSConVar.FLAG_ARCHIVE
	).with_min(0)
	console.cvar(
		"sv_notice_max_text", str(GSNotice.MAX_TEXT),
		"Longest notice text (characters); longer is cut with an error; 0 = unlimited.",
		GSConVar.FLAG_ARCHIVE
	).with_min(0)
	console.cvar(
		"sv_notice_max_id", str(GSNotice.MAX_ID),
		"Longest notice cue or topic (characters); longer is cut with an error; 0 = unlimited.",
		GSConVar.FLAG_ARCHIVE
	).with_min(0)
	console.cvar(
		"sv_notice_max_data_bytes", str(GSNotice.MAX_DATA_BYTES),
		"Largest encoded notice data (bytes); larger is dropped with an error; 0 = unlimited.",
		GSConVar.FLAG_ARCHIVE
	).with_min(0)
	console.cvar(
		"sv_notice_max_seconds", str(GSNotice.max_seconds),
		"Longest notice countdown (seconds); a longer one is refused; 0 = unlimited.",
		GSConVar.FLAG_ARCHIVE
	).with_min(0)
	console.cvar(
		"sv_max_immunity", str(GSAdminFlags.MAX_IMMUNITY),
		"Highest immunity an admin entry may hold; a higher or negative one is refused; 0 = unlimited.",
		GSConVar.FLAG_ARCHIVE
	).with_min(0)
	for limit_name in [
		"sv_envelope_max_kinds", "sv_envelope_max_kind_bytes", "sv_notice_max_text",
		"sv_notice_max_id", "sv_notice_max_data_bytes", "sv_notice_max_seconds", "sv_max_immunity",
	]:
		console.find_cvar(limit_name).changed.connect(
			func(_old: String, _new: String) -> void: apply_limit_cvars())


## Reads cvars back into the config after server.cfg has run.
func _apply_cvars_to_config() -> void:
	config.hostname = _cv_hostname.get_string()
	config.password = _cv_password.get_string()
	config.max_players = _cv_maxplayers.get_int()
	config.tickrate = _cv_tickrate.get_int()
	var tiers := GSTickTiers.parse(console.get_string("sv_tickrate_tiers", ""))
	if tiers.error != "":
		GSLog.warn(CHANNEL, "sv_tickrate_tiers ignored", {"why": tiers.error})
	elif not tiers.is_off() and config.max_players > 0:
		config.tickrate = tiers.rate_for(config.max_players, config.tickrate)
		GSLog.info(CHANNEL, "tick rate from sv_tickrate_tiers", {"slots": config.max_players, "tickrate": config.tickrate})
	config.client_timeout_sec = _cv_timeout.get_float()
	config.background_grace_max_sec = _cv_background_grace.get_float()
	config.reserved_slots = console.get_int("sv_reserved_slots", config.reserved_slots)
	config.max_connections_per_ip = console.get_int(
		"sv_max_connections_per_ip", config.max_connections_per_ip
	)
	config.query_enabled = console.get_bool("sv_query", config.query_enabled)
	config.a2s_enabled = console.get_bool("sv_a2s", config.a2s_enabled)
	config.query_player_detail = console.get_string(
		"sv_query_players", config.query_player_detail
	)
	config.hibernate_when_empty = console.get_bool(
		"sv_hibernate_when_empty", config.hibernate_when_empty
	)
	config.worker_threads = console.get_int("sv_worker_threads", config.worker_threads)
	config.worker_threads_auto_max = console.get_int(
		"sv_worker_threads_auto_max", config.worker_threads_auto_max
	)
	config.threads_net = console.get_bool("sv_threads_net", config.threads_net)
	config.threads_npc = console.get_bool("sv_threads_npc", config.threads_npc)
	config.net_native = console.get_bool("net_native", config.net_native)
	config.net_native_interest = console.get_bool("net_native_interest", config.net_native_interest)
	apply_limit_cvars()


## Pushes the limit cvars into the static settings the net, notice and admin classes read
## ([member GSEnvelope.max_kinds], [member GSNotice.max_text], [member GSAdminFlags.max_immunity] and
## the rest). Runs after server.cfg and again from the console whenever one of them changes.
func apply_limit_cvars() -> void:
	GSEnvelope.set_limits(
		console.get_int("sv_envelope_max_kinds", GSEnvelope.MAX_KINDS),
		console.get_int("sv_envelope_max_kind_bytes", GSEnvelope.MAX_KIND_BYTES))
	GSNotice.set_limits(
		console.get_int("sv_notice_max_text", GSNotice.MAX_TEXT),
		console.get_int("sv_notice_max_id", GSNotice.MAX_ID),
		console.get_int("sv_notice_max_data_bytes", GSNotice.MAX_DATA_BYTES))
	GSNotice.max_seconds = console.get_float("sv_notice_max_seconds", GSNotice.max_seconds)
	GSAdminFlags.set_max_immunity(console.get_int("sv_max_immunity", GSAdminFlags.MAX_IMMUNITY))


func _register_commands() -> void:
	GSBuiltinCommands.register_all(self, console)
