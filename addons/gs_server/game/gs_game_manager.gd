@tool
class_name GSGameManager
extends "res://addons/gs_server/game/gs_game_manager_switch.gd"

## Loads and switches the running game while clients stay connected.
## A changelevel is announce, clients download and mount, swap, re-spawn; a client that cannot get the content is dropped.
## GameSpice Cloud is found through [GSRegistry]. Godot cannot unmount a pack, so unload frees the scene (docs/game-switching.md).


func setup(p_server: Node) -> void:
	server = p_server
	GSRegistry.register(SERVICE, self)

	if game_root_ref == null:
		game_root_ref = GSNodeRef.of_created(&"GameRoot", Node)
	_game_root = game_root_ref.resolve_or_null(self, CHANNEL)

	server.client_state_changed.connect(_on_client_state_changed)

	if initial_game != "":
		var res := await change_game(initial_game, "boot")
		if not res.ok:
			GSLog.error(
				CHANNEL,
				"could not load the initial game",
				{"game": initial_game, "why": res.error.message}
			)


func _exit_tree() -> void:
	GSRegistry.unregister_instance(SERVICE, self)


## Switches to a game, syncing clients first.
## A failed change leaves the previous game running, never no game.
func change_game(game_id: String, by: String = "console") -> GSResult:
	if phase != Phase.IDLE:
		return GSResult.fail(
			GSError.CODE_STATE,
			"A game change is already in progress.",
			_pending.game_id if _pending != null else ""
		)

	var resolved := resolve_game(game_id)
	if not resolved.ok:
		return resolved

	var descriptor := resolved.value as GSGameDescriptor
	# Canonical id from here on, whichever spelling was typed.
	game_id = descriptor.game_id

	if _current != null and _current.game_id == game_id:
		return GSResult.fail(
			GSError.CODE_STATE, "'%s' is already running." % game_id
		)

	var validated := descriptor.validate()
	if not validated.ok:
		return validated

	if server.events != null:
		var event: GSEvent = server.events.fire("game_changing", {
			"from": current_content_key(),
			"to": descriptor.content_key(),
			"by": by,
		})
		if event.cancelled:
			return GSResult.fail(
				GSError.CODE_FORBIDDEN,
				"The game change was blocked.",
				event.cancel_reason
			)

	_pending = descriptor

	GSLog.info(
		CHANNEL,
		"changing game",
		{"to": descriptor.game_id, "by": by, "clients": server.player_count()}
	)

	server.game_changing.emit(current_content_key(), descriptor.content_key())

	if server.chat != null:
		server.chat.broadcast_system(
			"Changing to %s…" % descriptor.display_name_or_id()
		)

	# A game shipped inside the build has no content to fetch and swaps at once.
	if descriptor.needs_delivered_content():
		var delivered := await _deliver_content(descriptor)
		if not delivered.ok:
			phase = Phase.IDLE
			_pending = null
			game_load_failed.emit(descriptor.content_key(), delivered.error)
			return delivered

	var swapped := await _swap_to(descriptor)

	phase = Phase.IDLE
	_pending = null

	if not swapped.ok:
		game_load_failed.emit(descriptor.content_key(), swapped.error)
		return swapped

	return swapped


## Switches to the next game in the rotation.
func next_game(by: String = "console") -> GSResult:
	var order := rotation if not rotation.is_empty() else game_ids()

	if order.is_empty():
		return GSResult.fail(
			GSError.CODE_STATE, "No games are configured."
		)

	# Start from the current game's position so the rotation is stable across a
	# change made by any other means.
	if _current != null:
		var current_index := Array(order).find(_current.game_id)
		if current_index >= 0:
			_rotation_index = current_index

	_rotation_index = (_rotation_index + 1) % order.size()

	return await change_game(order[_rotation_index], by)

func _on_client_state_changed(session: GSClientSession) -> void:
	if phase != Phase.SYNCING:
		return
	if session.state != GSClientSession.State.LOADING:
		return

	# A client that reached LOADING during a sync has the content. The waiting loop
	# reads content_key, so nothing more is needed here than the log line.
	GSLog.debug(
		CHANNEL, "client synced during change", {"user": session.label()}
	)
