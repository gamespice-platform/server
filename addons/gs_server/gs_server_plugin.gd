@tool
extends EditorPlugin

## Editor entry point for GameSpice Server. Registers inspector types only.
## No autoloads: a project may run a server and a client in one process, which a singleton would forbid.

const _ICON := "res://addons/gs_server/icon_placeholder.svg"

const _TYPES := [
	["GSServer", "Node", "res://addons/gs_server/server/gs_server.gd"],
	["GSConsole", "Node", "res://addons/gs_server/console/gs_console.gd"],
	["GSAdminManager", "Node", "res://addons/gs_server/admin/gs_admin_manager.gd"],
	["GSBanManager", "Node", "res://addons/gs_server/moderation/gs_ban_manager.gd"],
	["GSAuditLog", "Node", "res://addons/gs_server/moderation/gs_audit_log.gd"],
	["GSRconServer", "Node", "res://addons/gs_server/rcon/gs_rcon_server.gd"],
	["GSChatManager", "Node", "res://addons/gs_server/chat/gs_chat_manager.gd"],
	["GSGameManager", "Node", "res://addons/gs_server/game/gs_game_manager.gd"],
	["GSVoteManager", "Node", "res://addons/gs_server/vote/gs_vote_manager.gd"],
	["GSEventBus", "Node", "res://addons/gs_server/events/gs_event_bus.gd"],
	["GSModuleHost", "Node", "res://addons/gs_server/modules/gs_module_host.gd"],
	["GSClientLink", "Node", "res://addons/gs_server/client/gs_client_link.gd"],
]


func _enter_tree() -> void:
	var icon: Texture2D = null
	if ResourceLoader.exists(_ICON):
		icon = load(_ICON) as Texture2D

	for entry in _TYPES:
		add_custom_type(entry[0], entry[1], load(entry[2]), icon)


func _exit_tree() -> void:
	# Reversed so a type is never removed before something that referenced it,
	# which matters when the editor reloads the plugin.
	for i in range(_TYPES.size() - 1, -1, -1):
		remove_custom_type(_TYPES[i][0])
