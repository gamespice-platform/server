extends "res://addons/gs_server/console/gs_builtin_commands_moderation.gd"

## Game, chat, vote and admin commands of [GSBuiltinCommands].


static func _register_games(server: Node, console: GSConsole) -> void:
	console.command(
		"changelevel",
		func(ctx: GSCmdContext) -> void:
			ctx.reply("Changing to %s…" % ctx.arg(0))
			var res: GSResult = await server.games.change_game(
				ctx.arg(0), ctx.caller_label()
			)
			if not res.ok:
				ctx.reply_error(res)
				return
			ctx.reply("Now running %s." % ctx.arg(0)),
		"Switch to another game or map.",
		GSAdminFlags.CHANGEMAP
	).with_usage("<game_id>").with_args(1, 1).with_chat().with_completer(
		func(_partial: String, _index: int) -> PackedStringArray:
			return server.games.game_ids()
	)

	# `game` and `gamechange`, deliberately NOT `map`: changing a GAME replaces the module and netcode and re-signs everybody on,
	# while changing a MAP replaces only the world and happens every few minutes, and the second is what an operator means
	# by `map`. `GSMapCommands` owns the plain name; these are the aliases for this one.
	for alias in ["game", "gamechange"]:
		console.command(
			alias,
			func(ctx: GSCmdContext) -> void:
				ctx.reply("Changing to %s…" % ctx.arg(0))
				var res: GSResult = await server.games.change_game(
					ctx.arg(0), ctx.caller_label()
				)
				if not res.ok:
					ctx.reply_error(res)
					return
				ctx.reply("Now running %s." % ctx.arg(0)),
			"Switch to another game. Alias for changelevel.",
			GSAdminFlags.CHANGEMAP
		).with_usage("<game_id>").with_args(1, 1).with_chat().with_completer(
			func(_partial: String, _index: int) -> PackedStringArray:
				return server.games.game_ids()
		)

	console.command(
		"nextgame",
		func(ctx: GSCmdContext) -> void:
			var res: GSResult = await server.games.next_game(ctx.caller_label())
			if not res.ok:
				ctx.reply_error(res),
		"Advance the game rotation.",
		GSAdminFlags.CHANGEMAP
	).with_chat()

	console.command(
		"games",
		func(ctx: GSCmdContext) -> void:
			ctx.reply_lines(server.games.describe_lines()),
		"List available games."
	).with_chat()

	console.command(
		"cloud_status",
		func(ctx: GSCmdContext) -> void:
			var cloud := GSRegistry.get_service(&"gs_cloud_client")
			if cloud == null:
				ctx.reply("gs-cloud is not installed.")
				return
			if cloud.has_method("describe_lines"):
				var lines: Variant = cloud.call("describe_lines")
				if lines is PackedStringArray:
					ctx.reply_lines(lines),
		"Show content cache status."
	)


static func _register_chat(server: Node, console: GSConsole) -> void:
	console.command(
		"say",
		func(ctx: GSCmdContext) -> void:
			var text := ctx.rest(0)
			if text == "":
				return
			server.chat.broadcast_system(text)
			ctx.reply("Said: %s" % text),
		"Send a message to everyone.",
		GSAdminFlags.CHAT
	).with_usage("<text>").with_args(1)

	console.command(
		"asay",
		func(ctx: GSCmdContext) -> void:
			var text := ctx.rest(0)
			if text == "":
				return
			var from: String = ctx.session.display_name if ctx.session != null else "Console"
			server.chat.broadcast_admin(from, text),
		"Send a message to admins only.",
		GSAdminFlags.CHAT
	).with_usage("<text>").with_args(1).with_chat()

	console.command(
		"psay",
		func(ctx: GSCmdContext) -> void:
			var resolved: GSResult = server.resolve_target(ctx, ctx.arg(0))
			if not resolved.ok:
				ctx.reply_error(resolved)
				return

			var session: GSClientSession = resolved.value
			var text := ctx.rest(1)
			server.chat.send_system_to(session, text)
			ctx.reply("Sent to %s." % session.display_name),
		"Send a private message to a player.",
		GSAdminFlags.CHAT
	).with_usage("<player> <text>").with_args(2).with_chat()


static func _register_votes(server: Node, console: GSConsole) -> void:
	console.command(
		"votemap",
		func(ctx: GSCmdContext) -> void:
			var resolved: GSResult = server.games.resolve_game(ctx.arg(0))

			if not resolved.ok:
				ctx.reply("%s %s" % [resolved.error.message, resolved.error.detail])
				return

			var game_id := (resolved.value as GSGameDescriptor).game_id

			var res: GSResult = server.votes.start(
				"changelevel",
				"Change to %s?" % game_id,
				ctx.session,
				func(_vote: Dictionary) -> void:
					# Queued rather than awaited: this runs inside the vote
					# manager's own signal handling, and a game change frees
					# nodes.
					console.enqueue("changelevel %s" % game_id),
				{"game_id": game_id}
			)

			if not res.ok:
				ctx.reply_error(res),
		"Start a vote to change the game.",
		GSAdminFlags.VOTE
	).with_usage("<game_id>").with_args(1, 1).with_chat()

	console.command(
		"yes",
		func(ctx: GSCmdContext) -> void:
			if ctx.session == null:
				ctx.reply("Only players can vote.")
				return
			var res: GSResult = server.votes.cast_vote(ctx.session, true)
			ctx.reply(str(res.value_or(res.error.message if res.error else ""))),
		"Vote yes."
	).with_chat()

	console.command(
		"no",
		func(ctx: GSCmdContext) -> void:
			if ctx.session == null:
				ctx.reply("Only players can vote.")
				return
			var res: GSResult = server.votes.cast_vote(ctx.session, false)
			ctx.reply(str(res.value_or(res.error.message if res.error else ""))),
		"Vote no."
	).with_chat()

	console.command(
		"vote_status",
		func(ctx: GSCmdContext) -> void:
			ctx.reply_lines(server.votes.describe_lines()),
		"Show the running vote."
	).with_chat()

	console.command(
		"vote_cancel",
		func(ctx: GSCmdContext) -> void:
			var res: GSResult = server.votes.cancel("cancelled by %s" % ctx.caller_label())
			if not res.ok:
				ctx.reply_error(res)
				return
			ctx.reply("Vote cancelled."),
		"Cancel the running vote.",
		GSAdminFlags.VOTE
	)


static func _register_admin(server: Node, console: GSConsole) -> void:
	console.command(
		"admins",
		func(ctx: GSCmdContext) -> void:
			ctx.reply_lines(server.admins.describe_lines()),
		"Show admin entries and groups.",
		GSAdminFlags.ADMIN
	)

	console.command(
		"admin_flags",
		func(ctx: GSCmdContext) -> void:
			ctx.reply_lines(GSAdminFlags.describe_lines()),
		"List permission flags."
	)

	console.command(
		"admin_reload",
		func(ctx: GSCmdContext) -> void:
			var res: GSResult = server.admins.load_admins()
			if not res.ok:
				ctx.reply_error(res)
				return
			ctx.reply("Reloaded %d admin entries." % res.value)

			# Re-resolve everyone who is already connected: a promotion that only
			# applies to future joins is a confusing half-measure.
			for session in server.sessions():
				server.admins.resolve(session),
		"Reload the admin file.",
		GSAdminFlags.ADMIN
	)
	_register_admin_add(server, console)


static func _register_admin_add(server: Node, console: GSConsole) -> void:
	console.command(
		"admin_add",
		func(ctx: GSCmdContext) -> void:
			# A group name and a flag list are both legal here and telling them apart is this block: the admin file has groups
			# (moderator, admin, owner), but `GSAdminFlags.parse` accepts any token, so a group word became a flag that grants
			# nothing and only a log line hinted at it.
			var token := ctx.arg(1)
			var groups := PackedStringArray()
			var flags := PackedStringArray()

			if server.admins.has_group(token):
				groups.append(token)
			else:
				flags = GSAdminFlags.parse(token)

				# Refuse a token that is neither a known group nor any known flag. A game's own flags are legal and unknown,
				# but a lone word matching NOTHING is far more often a misspelled group, and silently granting
				# nothing is the outcome to prevent.
				var recognised := false

				for flag in flags:
					if GSAdminFlags.ALL.has(str(flag)):
						recognised = true
						break

				if not recognised:
					var known: String = ", ".join(server.admins.group_names())
					ctx.reply(
						"'%s' is neither a group nor a known flag." % token
					)
					ctx.reply("Groups: %s" % (known if known != "" else "(none)"))
					ctx.reply("Flags:  use `admin_flags` for the list.")
					return

			var immunity := ctx.arg_int(2, 0)

			var res: GSResult = server.admins.set_admin(
				ctx.arg(0), flags, immunity, groups, ctx.arg(3)
			)
			if not res.ok:
				ctx.reply_error(res)
				return

			var granted := (
				"group %s" % token if not groups.is_empty()
				else GSAdminFlags.format(flags)
			)

			ctx.reply("Admin set: %s -> %s (immunity %d)" % [
				ctx.arg(0), granted, immunity
			])

			if server.audit != null:
				server.audit.record(
					"admin_add", ctx.caller_label(), ctx.arg(0),
					{
						"flags": Array(flags),
						"groups": Array(groups),
						"immunity": immunity,
					}
				),
		"Grant permissions to an account id, by group or by flags.",
		GSAdminFlags.ADMIN
	).with_usage("<uid> <group|flags> [immunity] [name]").with_args(2)
	_register_admin_remove(server, console)


static func _register_admin_remove(server: Node, console: GSConsole) -> void:
	console.command(
		"admin_remove",
		func(ctx: GSCmdContext) -> void:
			var res: GSResult = server.admins.remove_admin(ctx.arg(0))
			if not res.ok:
				ctx.reply_error(res)
				return
			ctx.reply("Removed admin entry for %s." % ctx.arg(0))

			if server.audit != null:
				server.audit.record(
					"admin_remove", ctx.caller_label(), ctx.arg(0), {}
				),
		"Revoke an account's permissions.",
		GSAdminFlags.ADMIN
	).with_usage("<uid>").with_args(1, 1)

	console.command(
		"whoami",
		func(ctx: GSCmdContext) -> void:
			ctx.reply("caller    %s" % ctx.caller_label())
			ctx.reply("via       %s" % ctx.source_name())
			ctx.reply("flags     %s" % GSAdminFlags.format(ctx.permissions))
			ctx.reply("immunity  %d" % ctx.immunity),
		"Show your own permissions."
	).with_chat()

	console.command(
		"rcon_status",
		func(ctx: GSCmdContext) -> void:
			if server.rcon == null:
				ctx.reply("RCON is disabled.")
				return
			ctx.reply_lines(server.rcon.describe_lines()),
		"Show RCON sessions.",
		GSAdminFlags.RCON
	)
