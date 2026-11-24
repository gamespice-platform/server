@tool
extends "res://addons/gs_server/game/gs_game_manager_state.gd"

## Content fetch, client sync and scene swap of [GSGameManager].

## Fetches the content here first, then has every client fetch it.
##
## Server first, so a server that cannot get it abandons the change while nobody has been disturbed.
func _deliver_content(descriptor: GSGameDescriptor) -> GSResult:
	var have := await _acquire_content(descriptor)
	if not have.ok:
		return have

	return await _sync_clients(descriptor)


## Downloads and mounts the new game's content on this server, through GameSpice Cloud from [GSRegistry].
## An absent cloud client is a refusal: a manifest_url says the content is delivered, and clients
## must not be asked for what the server cannot load.
func _acquire_content(descriptor: GSGameDescriptor) -> GSResult:
	var cloud := GSRegistry.get_service(&"gs_cloud_client")

	if cloud == null or not cloud.has_method("ensure"):
		return GSResult.fail(
			GSError.CODE_STATE,
			"'%s' is delivered content and gs-cloud is not installed."
				% descriptor.game_id,
			"add a GSCloudClient to this server, or ship the game inside the build "
			+ "by clearing its manifest_url"
		)

	GSLog.info(
		CHANNEL,
		"fetching the new game's content",
		{
			"game": descriptor.game_id,
			"content": descriptor.content_key(),
			"url": descriptor.manifest_url if descriptor.manifest_url != ""
				else "(by id)",
		}
	)

	var groups := PackedStringArray()
	for group in descriptor.content_groups:
		groups.append(String(group))
	# The server loads whichever map the rotation picks, so it fetches every group (GameSpice Cloud API 22's
	# "*"); a client fetches its map's group on demand. An older GameSpice Cloud reads "*" as a name matching nothing.
	groups.append("*")

	# `ensure` is told the id and version too, so it refuses a manifest that does not answer to
	# them (a mirror serving one game's pack under another's name); `acquire` mounts anything.
	var acquired: Variant = await cloud.call(
		"ensure",
		descriptor.effective_content_id(),
		descriptor.version,
		groups,
		descriptor.manifest_url
	)

	if acquired is GSResult:
		var typed: GSResult = acquired
		if not typed.ok:
			return typed.wrap(
				"Could not get %s's content." % descriptor.game_id
			)

		# Dependencies and server-only packs are fetched here too, so an unobtainable one abandons
		# the change before any client downloads. Server-only ones never reach content.sync.
		for key in descriptor.dependencies + descriptor.server_dependencies:
			var parts := GSGameDescriptor.split_key(key)
			var dep: Variant = await cloud.call("ensure", parts[0], parts[1])
			if not (dep is GSResult) or not (dep as GSResult).ok:
				var why := (dep as GSResult) if dep is GSResult else GSResult.fail(
					GSError.CODE_INTERNAL, "The cloud client returned no result."
				)
				return why.wrap(
					"Could not get %s, which %s needs." % [key, descriptor.game_id]
				)

		return typed

	return GSResult.fail(
		GSError.CODE_INTERNAL,
		"The cloud client returned something that is not a GSResult.",
		str(acquired)
	)


## Tells every client to fetch the new content and waits for them.
func _sync_clients(descriptor: GSGameDescriptor) -> GSResult:
	phase = Phase.SYNCING
	_sync_deadline = int(Time.get_unix_time_from_system()) + int(sync_timeout_sec)

	# Built by the server: it is the same payload the join path sends, and a copy here drifted.
	var info: Dictionary = server.content_sync_info(
		descriptor.manifest_url,
		Array(descriptor.content_groups),
		descriptor.content_key(),
		descriptor.dependencies
	)

	var expected := 0

	for session in server.sessions():
		if _send_content_sync(session, info):
			expected += 1

	if expected == 0:
		return GSResult.success(0)

	GSLog.info(
		CHANNEL, "waiting for clients to sync", {"clients": expected}
	)

	while true:
		await get_tree().create_timer(0.5).timeout

		if not is_inside_tree():
			return GSResult.fail(
				GSError.CODE_CANCELLED, "The server is shutting down."
			)

		var ready_count := 0
		var waiting := 0

		for session in server.sessions():
			if not session.is_active():
				continue
			if session.content_key == descriptor.content_key():
				ready_count += 1
			elif session.state == GSClientSession.State.DOWNLOADING:
				waiting += 1

		change_progress.emit(ready_count, ready_count + waiting)

		# Off, the change waits out the whole timeout even when everybody is ready.
		if waiting == 0 and swap_when_all_ready:
			GSLog.info(CHANNEL, "all clients synced", {"clients": ready_count})
			return GSResult.success(ready_count)

		if int(Time.get_unix_time_from_system()) >= _sync_deadline:
			_on_sync_timeout(ready_count, waiting)
			# Proceeding, not failing: the ones who got the content keep their change.
			return GSResult.success(ready_count)

	return GSResult.success(0)


## Moves one session to DOWNLOADING and sends it the sync. False when it is not waited for.
func _send_content_sync(session: GSClientSession, info: Dictionary) -> bool:
	if not session.is_active():
		return false
	# A client still authenticating, or held in PROFILE, reaches the new content through the
	# normal join flow; moving a held one to DOWNLOADING would let it past its holder.
	if session.state == GSClientSession.State.CONNECTING \
		or session.state == GSClientSession.State.AUTHENTICATING \
		or session.state == GSClientSession.State.PROFILE:
		return false

	session.content_progress = 0.0
	# Cleared, not left: the wait loop compares content_key, and a client that played this game
	# earlier still holds the new key, so it would be counted ready before the RPC even arrived.
	session.content_key = ""

	if not session.transition_to(GSClientSession.State.DOWNLOADING):
		GSLog.warn(
			CHANNEL,
			"a client could not be sent to download",
			{"user": session.label(), "state": session.state_name()}
		)
		return false

	# Announced like every other state change; modules and admin panels hear it from the signal.
	server.client_state_changed.emit(session)
	server.send_kind(session.peer_id, GSEnvelope.CONTENT_SYNC, info)
	return true


func _on_sync_timeout(ready_count: int, waiting: int) -> void:
	GSLog.warn(
		CHANNEL,
		"content sync timed out",
		{"ready": ready_count, "waiting": waiting}
	)

	if not kick_on_content_timeout:
		return

	for session in server.sessions():
		if session.state == GSClientSession.State.DOWNLOADING:
			server.kick(session, "Could not download the new game content in time")


## Frees the old scene and instantiates the new one.
func _swap_to(descriptor: GSGameDescriptor) -> GSResult:
	phase = Phase.SWAPPING

	var previous := _current

	_unload_current()

	var scene_path := descriptor.resolve_scene_path()

	if scene_path == "":
		return GSResult.fail(
			GSError.CODE_INVALID,
			"'%s' has no scene to load." % descriptor.game_id
		)

	if not ResourceLoader.exists(scene_path):
		# Restore the previous game so a wrong scene name inside synced content leaves a game.
		GSLog.error(
			CHANNEL,
			"the game scene is missing",
			{"game": descriptor.game_id, "path": scene_path}
		)

		if previous != null:
			GSLog.info(CHANNEL, "restoring the previous game")
			_current = previous
			_instantiate(previous.resolve_scene_path())

		return GSResult.fail(
			GSError.CODE_IO, "The game scene is missing.", scene_path
		)

	var instantiated := _instantiate(scene_path)
	if not instantiated.ok:
		return instantiated

	_current = descriptor

	# Through `set_cvar`, so validators and the `changed` signal apply; a direct write moves nobody.
	_apply_descriptor_cvars(descriptor, false)

	if server.console != null:
		server.console.exec_config(
			server.config.game_config_prefix + descriptor.game_id, null, false
		)

	GSLog.info(
		CHANNEL,
		"game loaded",
		{"game": descriptor.game_id, "scene": scene_path}
	)

	_restart_loading(descriptor)

	if server.events != null:
		server.events.notify("game_changed", {
			"game": descriptor.game_id,
			"content_key": descriptor.content_key(),
		})

	game_loaded.emit(descriptor.content_key())

	if server.chat != null:
		server.chat.broadcast_system(
			"Now playing %s." % descriptor.display_name_or_id()
		)

	return GSResult.success(descriptor)


## Puts everyone who has the content back through loading so the client rebuilds its scene.
##
## Only sessions that got as far as loading once: one still connecting is sent the game by the join flow.
func _restart_loading(descriptor: GSGameDescriptor) -> void:
	for session in server.sessions():
		if not session.is_active():
			continue
		if session.state != GSClientSession.State.DOWNLOADING \
			and session.state != GSClientSession.State.LOADING \
			and session.state != GSClientSession.State.SPAWNED:
			continue
		if session.content_key == descriptor.content_key() \
			or not descriptor.needs_delivered_content():
			session.transition_to(GSClientSession.State.LOADING)
			server._send_load_game(session)


## Applies a descriptor's [member GSGameDescriptor.cvars].
## An unregistered name is counted, not wrong, on the first pass (its module loads after [signal game_loaded]);
## [method reapply_descriptor_cvars] is where it is wrong. A registered cvar refusing its value always warns.
func _apply_descriptor_cvars(descriptor: GSGameDescriptor, unknown_is_wrong: bool) -> int:
	if server.console == null or descriptor.cvars.is_empty():
		return 0

	var applied := 0
	var unknown := PackedStringArray()

	for name: Variant in descriptor.cvars:
		var cvar_name := str(name)
		var value := str(descriptor.cvars[name])

		if server.console.find_cvar(cvar_name) == null:
			unknown.append(cvar_name)

			if unknown_is_wrong:
				GSLog.warn(CHANNEL, "a game names a cvar nothing registers", {
					"game": descriptor.game_id, "cvar": cvar_name, "value": value,
					"hint": "a typo, or a module that did not load",
				})

			continue

		var result: GSResult = server.console.set_cvar(cvar_name, value)

		if result.ok:
			applied += 1
			continue

		GSLog.warn(CHANNEL, "a game's cvar was refused its value", {
			"game": descriptor.game_id, "cvar": cvar_name, "value": value,
			"why": result.error.message,
		})

	GSLog.info(CHANNEL, "the game's cvars were applied", {
		"game": descriptor.game_id,
		"applied": applied,
		"of": descriptor.cvars.size(),
		"not_registered_yet": Array(unknown),
	})

	return applied


## Applies the running game's cvars again. For a host that has just loaded its module.
##
## The first pass runs before a host registers the module's cvars, so those were refused as unknown.
func reapply_descriptor_cvars() -> int:
	if _current == null:
		return 0

	return _apply_descriptor_cvars(_current, true)


func _instantiate(scene_path: String) -> GSResult:
	var packed := load(scene_path)
	if not (packed is PackedScene):
		return GSResult.fail(
			GSError.CODE_INVALID,
			"The game scene is not a PackedScene.",
			scene_path
		)

	var instance := (packed as PackedScene).instantiate()
	if instance == null:
		return GSResult.fail(
			GSError.CODE_INTERNAL,
			"The game scene could not be instantiated.",
			scene_path
		)

	if _game_root == null:
		_game_root = game_root_ref.resolve_or_null(self, CHANNEL)
	if _game_root == null:
		instance.queue_free()
		return GSResult.fail(
			GSError.CODE_STATE, "There is no game root node to add the scene to."
		)

	if server != null:
		_server_children_before_game = server.get_children()

	_scene_instance = instance
	_game_root.add_child(instance)

	return GSResult.success(instance)


## Frees the running scene.
##
## Freed at once, not queued: two games in the tree for a frame duplicate nodes, groups and physics.
func _unload_current() -> void:
	if _scene_instance == null:
		return

	var previous_key := current_content_key()

	if is_instance_valid(_scene_instance):
		_game_root.remove_child(_scene_instance)
		_scene_instance.free()

	_scene_instance = null

	_free_game_children()

	# The map belonged to the game that just went. Cleared here rather than when the
	# next one loads, because the next game's module is what sets it again and it does
	# so from `game_loaded`, after this.
	_current_map = ""
	_current_map_groups = PackedStringArray()

	# Release the old content's cache references so GameSpice Cloud may evict it. The
	# pack's file table stays mounted — the engine offers no way to remove it — but
	# nothing points at those paths any more.
	var cloud := GSRegistry.get_service(&"gs_cloud_client")
	if cloud != null and previous_key != "" and cloud.has_method("release"):
		cloud.call("release", previous_key)

	GSLog.debug(CHANNEL, "previous game unloaded", {"was": previous_key})


## Retires what the game that just went put under the server: its RPC link, above all.
## Renamed now, freed [constant RETIRED_SECONDS] later: left in place, the next load of the same game was
## renamed `@Node@<n>` and the RPC paths disagreed; freed at once, in-flight requests were engine errors.
func _free_game_children() -> void:
	if server == null or not is_instance_valid(server):
		_server_children_before_game.clear()
		return

	var retired: Array[Node] = []

	for child in server.get_children():
		if child in _server_children_before_game:
			continue
		# A module that survives the switch (a mode change inside one pack rebinds its bridge, it does not rebuild it) still owns its link; retiring it left every later RPC to "Server/<link>" with no node.
		if _link_of_live_bridge(child):
			continue
		retired.append(child)
		child.name = "%s_retired_%d" % [child.name, child.get_instance_id()]

	_server_children_before_game.clear()

	if retired.is_empty() or not server.is_inside_tree():
		return

	GSLog.debug(CHANNEL, "retired what the game left under the server", {
		"nodes": retired.size(),
	})

	server.get_tree().create_timer(RETIRED_SECONDS, true, false, true).timeout.connect(
		_free_ids.bind(retired.map(func(n: Node) -> int: return n.get_instance_id())))


## True for a game's RPC link whose bridge is still in the tree: the bridge frees the link itself when it leaves.
static func _link_of_live_bridge(child: Node) -> bool:
	if not ("bridge" in child):
		return false
	var bridge: Variant = child.get("bridge")
	return bridge is Node and is_instance_valid(bridge) and (bridge as Node).is_inside_tree()


## Frees the nodes still alive by instance id; a lambda capturing them errors once one is freed early.
static func _free_ids(ids: Array) -> void:
	for id in ids:
		var node := instance_from_id(id) as Node
		if node != null and not node.is_queued_for_deletion():
			node.queue_free()
