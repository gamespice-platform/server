class_name GSBuiltinCommands
extends "res://addons/gs_server/console/gs_builtin_commands_games.gd"

## Registers the standard console commands, named after the established ones (status, kickid, changelevel, exec) so operators need no lookup.
## Deliberately a static class beside [GSServer]: the whole command surface and each permission reads as one list.


# No `const CHANNEL`. Each command replies to whoever typed it, and the things an operator
# wants in a log (a kick, a ban, a map change) are logged by the server and the ban
# manager these commands call, where every other path to them is logged as well.

# Query commands are registered by GameSpice Server Query when it attaches (see GSServer.attach_query_host).


static func register_all(server: Node, console: GSConsole) -> void:
	_register_help(server, console)
	_register_status(server, console)
	_register_players(server, console)
	_register_moderation(server, console)
	_register_games(server, console)
	_register_chat(server, console)
	_register_votes(server, console)
	_register_admin(server, console)
	_register_modules(server, console)
	_register_config(server, console)
	_register_lifecycle(server, console)


static func _register_modules(server: Node, console: GSConsole) -> void:
	console.command(
		"modules",
		func(ctx: GSCmdContext) -> void:
			ctx.reply_lines(server.modules.describe_lines()),
		"List loaded modules."
	)

	console.command(
		"module_load",
		func(ctx: GSCmdContext) -> void:
			var res: GSResult = await server.modules.load_module(ctx.arg(0))
			if not res.ok:
				ctx.reply_error(res)
				return
			ctx.reply("Loaded %s." % res.value._module_name()),  # a GSModule, left untyped (the module script names GSServer)
		"Load a module from a script path.",
		GSAdminFlags.MODULES
	).with_usage("<path>").with_args(1, 1)

	console.command(
		"module_unload",
		func(ctx: GSCmdContext) -> void:
			var res: GSResult = server.modules.unload_module(ctx.arg(0))
			if not res.ok:
				ctx.reply_error(res)
				return
			ctx.reply("Unloaded %s." % ctx.arg(0)),
		"Unload a module.",
		GSAdminFlags.MODULES
	).with_usage("<name>").with_args(1, 1)

	console.command(
		"module_reload",
		func(ctx: GSCmdContext) -> void:
			var res: GSResult = await server.modules.reload_module(ctx.arg(0))
			if not res.ok:
				ctx.reply_error(res)
				return
			ctx.reply("Reloaded %s." % ctx.arg(0)),
		"Reload a module from disk.",
		GSAdminFlags.MODULES
	).with_usage("<name>").with_args(1, 1)

	console.command(
		"events",
		func(ctx: GSCmdContext) -> void:
			ctx.reply_lines(server.events.describe_lines()),
		"List game events and their hook counts."
	)


static func _register_config(server: Node, console: GSConsole) -> void:
	console.command(
		"exec",
		func(ctx: GSCmdContext) -> void:
			var res := console.exec_config(ctx.arg(0), ctx, true)
			if not res.ok:
				ctx.reply_error(res)
				return
			ctx.reply("Executed %s (%d lines)." % [ctx.arg(0), res.value]),
		"Execute a config file.",
		GSAdminFlags.CONFIG
	).with_usage("<file>").with_args(1, 1)

	console.command(
		"writeconfig",
		func(ctx: GSCmdContext) -> void:
			var res := console.write_config(ctx.arg(0, "server_saved"))
			if not res.ok:
				ctx.reply_error(res)
				return
			ctx.reply("Wrote %s." % res.value),
		"Save archived variables to a config file.",
		GSAdminFlags.CONFIG
	).with_usage("[name]")

	console.command(
		"config_dump",
		func(ctx: GSCmdContext) -> void:
			ctx.reply_lines(server.config.describe_lines(true)),
		"Show the boot configuration.",
		GSAdminFlags.CONFIG
	)
	_register_config_log(server, console)


static func _register_config_log(server: Node, console: GSConsole) -> void:
	console.command(
		"reset",
		func(ctx: GSCmdContext) -> void:
			var cvar := console.find_cvar(ctx.arg(0))
			if cvar == null:
				ctx.reply("Unknown variable '%s'." % ctx.arg(0))
				return
			cvar.reset()
			ctx.reply("%s reset to %s." % [cvar.name, cvar.display_value()]),
		"Reset a variable to its default.",
		GSAdminFlags.CVAR
	).with_usage("<cvar>").with_args(1, 1)

	console.command(
		"log_level",
		func(ctx: GSCmdContext) -> void:
			if ctx.argc() == 0:
				ctx.reply("Log level is %s." % GSLog.level_name(GSLog.get_level()))
				return

			if ctx.argc() == 1:
				var level := GSLog.parse_level(ctx.arg(0))
				if level < 0:
					ctx.reply(
						"Unknown level '%s'. Use: %s"
							% [ctx.arg(0), ", ".join(GSLog.LEVEL_NAMES)]
					)
					return
				GSLog.set_level(level)
				ctx.reply("Log level set to %s." % GSLog.level_name(level))
				return

			# Two arguments sets a channel level, which is what you want when one
			# subsystem is misbehaving and the rest is fine.
			var channel_level := GSLog.parse_level(ctx.arg(1))
			if channel_level < 0:
				ctx.reply("Unknown level '%s'." % ctx.arg(1))
				return
			GSLog.set_channel_level(ctx.arg(0), channel_level)
			ctx.reply("Log level for '%s' set to %s." % [
				ctx.arg(0), GSLog.level_name(channel_level)
			]),
		"Get or set the log level, globally or per channel.",
		GSAdminFlags.CONFIG
	).with_usage("[channel] <level>")


static func _register_lifecycle(server: Node, console: GSConsole) -> void:
	console.command(
		"quit",
		func(ctx: GSCmdContext) -> void:
			var reason := ctx.rest(0)
			if reason == "":
				reason = "Server shutting down"
			ctx.reply("Shutting down: %s" % reason)
			server.shutdown(reason)
			# Deferred so the reply reaches an RCON client before the socket
			# closes.
			server.get_tree().quit.call_deferred(),
		"Shut the server down.",
		GSAdminFlags.ROOT
	# `quit` ends the session for everybody and cannot be undone, so chat is refused it outright:
	# a stray relayed line must not reach the one command with no confirmation step.
	).with_usage("[reason]").with_rcon(true).no_chat()

	console.command(
		"say_shutdown",
		func(ctx: GSCmdContext) -> void:
			var seconds := ctx.arg_int(0, 30)
			server.chat.broadcast_system(
				"Server restarting in %d seconds." % seconds
			)
			ctx.reply("Announced a restart in %ds." % seconds)
			# `wait` is measured in frames, so the delay is expressed in ticks.
			console.enqueue(
				"wait %d; quit Scheduled restart"
					% (seconds * Engine.physics_ticks_per_second)
			),
		"Announce and schedule a shutdown.",
		GSAdminFlags.ROOT
	).with_usage("[seconds]")
