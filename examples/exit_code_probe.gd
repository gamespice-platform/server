extends Node

## Boots a server with a stdin console, shuts it down and quits with exit code 75, the
## way GameSpice Cloud's auto-update does. Run by examples/exit_code_check.sh under a real pipe
## and a pty, which assert the process status is 75.


func _ready() -> void:
	var config := GSServerConfig.new()
	config.port = 0
	config.rcon_port = 0
	config.stdin_console_pipes = true
	var server := GSServer.new()
	server.config = config
	server.auto_boot = false
	add_child(server)
	await server.boot()
	await get_tree().create_timer(0.5).timeout
	print("probe: stdin console ", server.stdin_console.describe() if server.stdin_console else "none")
	server.shutdown("probe")
	get_tree().quit(75)
