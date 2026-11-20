extends Node

## A game module whose net bridge no longer compiles against the installed addons must fail to
## load with the bridge's parse error in the result, not only the module's own conclusion. This is
## game-hungario 0.1.19 on 2026-11-19: `var net_id := identity.net_id` stopped inferring once
## dot-net typed `identity` as Node, the bridge came back null and the host logged only "A game
## has to supply the bridge between itself and the netcode."
##
## Run by examples/module_load_error_check.sh, not as a suite: the fixture prints a real Parse
## Error, which the suite runner rightly fails on.

const ROOT := "user://module_load_error"
const NETCODE := "A game has to supply the bridge between itself and the netcode."

const MODULE := """extends DotModule

func _module_name() -> String: return "%s"

func _module_load() -> DotResult:
	var root := (get_script() as Script).resource_path.get_base_dir().get_base_dir()
	var bridge_script: Variant = load(root.path_join("net/bridge.gd"))
	var bridge: Variant = null
	if bridge_script is GDScript and (bridge_script as GDScript).can_instantiate():
		bridge = (bridge_script as GDScript).new()
	if bridge == null:
		return DotResult.fail(DotError.CODE_INVALID, "the netcode could not start", "%s")
	return DotResult.success(null)
"""

## Refuses for a reason of its own; every script of its game compiles.
const REFUSES := """extends DotModule

func _module_name() -> String: return "plain"

func _module_load() -> DotResult:
	return DotResult.fail(DotError.CODE_INVALID, "the netcode could not start", "%s")
"""

const BRIDGE_UNTYPED := """extends RefCounted

var identity: Node = null

func net_id_of() -> int:
	var net_id := identity.net_id
	return net_id
"""

const BRIDGE_TYPED := """extends RefCounted

var identity: Node = null

func net_id_of() -> int:
	var net_id: int = identity.net_id
	return net_id
"""

## Uses the bridge but has no error of its own: it must not be reported.
const USES_BRIDGE := """extends RefCounted

const Bridge := preload("bridge.gd")

func make() -> int:
	var bridge: Bridge = Bridge.new()
	return bridge.net_id_of()
"""

## Fails only because the script it extends does not compile: listed after the bridge, as a follow-on.
const EXTENDS_BRIDGE := """extends "bridge.gd"

func again() -> int:
	return net_id_of()
"""

var _fails := 0


func _ready() -> void:
	var config := DotServerConfig.new()
	config.port = 0
	config.rcon_port = 0
	config.startup_config = ""
	var server := DotServer.new()
	server.config = config
	server.auto_boot = false
	add_child(server)
	await server.boot()

	# The failure: a delivered-style layout (game.yml at the root, the module and bridge below it).
	var broken := _write_game("broken", BRIDGE_UNTYPED)
	var res: DotResult = await server.modules.load_module(broken + "/scripts/module.gd")
	var text := str(res.error) if not res.ok else ""
	print("module_load_error: broken -> ", text)
	_check("the broken bridge fails the load", not res.ok)
	_check("the module's own conclusion is kept", text.contains(NETCODE))
	var line := BRIDGE_UNTYPED.split("\n").find("\tvar net_id := identity.net_id") + 1
	_check(
		"the bridge's parse error is named with its file and line",
		text.contains("net/bridge.gd:%d:" % line) and text.contains("Cannot infer the type of \"net_id\"")
	)
	_check("a script that only uses the bridge is not blamed", not text.contains("uses_bridge.gd"))
	var own_at := text.find("net/bridge.gd:%d:" % line)
	var follow_at := text.find("net/extends_bridge.gd does not compile")
	_check(
		"a script that fails only through the bridge is listed after the bridge's own error",
		text.contains("The game has 2 scripts that do not compile") and own_at >= 0 and follow_at > own_at
			and text.contains("net/extends_bridge.gd does not compile: net/extends_bridge.gd:1: Parse Error: Could not resolve")
	)

	# The production path: the same broken game delivered as a pack mounted under res://dot_cloud/. A pack published
	# without a site claim mounts at res://dot_cloud/<id>/<version> (no owner), and its root is still found by game.yml.
	var mounted := _mount_game("mod-load-mounted", "0.0.1", BRIDGE_UNTYPED)
	var m_res: DotResult = await server.modules.load_module(mounted + "/scripts/module.gd")
	var m_text := str(m_res.error) if not m_res.ok else ""
	print("module_load_error: mounted -> ", m_text)
	_check(
		"a mounted pack's bridge parse error is named with its file and line",
		not m_res.ok and m_text.contains(NETCODE) and m_text.contains("net/bridge.gd:%d:" % line)
			and m_text.contains("Cannot infer the type of \"net_id\"")
	)

	# The same game with the declaration typed loads.
	var fixed := _write_game("fixed", BRIDGE_TYPED)
	var ok: DotResult = await server.modules.load_module(fixed + "/scripts/module.gd")
	_check("the typed bridge loads", ok.ok)
	if ok.ok:
		server.modules.unload_module("fixed")

	# A refusal in a game whose scripts all compile is reported as the module said, nothing added.
	var plain := _write_game("plain", BRIDGE_TYPED)
	DotPaths.write_text(plain + "/scripts/module.gd", REFUSES % NETCODE)
	var plain_res: DotResult = await server.modules.load_module(plain + "/scripts/module.gd")
	var plain_text := str(plain_res.error) if not plain_res.ok else ""
	_check(
		"a refusal with every script compiling names no script",
		not plain_res.ok and plain_text.contains(NETCODE) and not plain_text.contains("does not compile")
	)

	# A module script that does not compile names its own error rather than "the log above".
	var bad := _write_game("bad_module", BRIDGE_TYPED)
	DotPaths.write_text(bad + "/scripts/module.gd", "extends DotModule\n\nfunc _module_name() -> String:\n\treturn undefined_name\n")
	var bad_res: DotResult = await server.modules.load_module(bad + "/scripts/module.gd")
	var bad_text := str(bad_res.error) if not bad_res.ok else ""
	print("module_load_error: bad module -> ", bad_text)
	_check(
		"an uncompilable module names its parse error",
		not bad_res.ok and bad_text.contains("Caused by a script that does not compile: scripts/module.gd:4:")
			and bad_text.contains("undefined_name")
	)

	server.shutdown("probe")
	print("module_load_error: %d failed" % _fails)
	get_tree().quit(1 if _fails > 0 else 0)


func _write_game(name_: String, bridge: String) -> String:
	var root := ROOT.path_join(name_)
	DotPaths.write_text(root + "/game.yml", "id: %s\n" % name_)
	DotPaths.write_text(root + "/scripts/module.gd", MODULE % [name_, NETCODE])
	DotPaths.write_text(root + "/net/bridge.gd", bridge)
	DotPaths.write_text(root + "/net/uses_bridge.gd", USES_BRIDGE)
	DotPaths.write_text(root + "/net/extends_bridge.gd", EXTENDS_BRIDGE)
	return root


## Packs the game's files into a .pck and mounts it at res://dot_cloud/<id>/<version>, as dot-cloud's mounter does.
func _mount_game(id: String, version: String, bridge: String) -> String:
	var src := _write_game(id, bridge)
	var at := "res://dot_cloud/%s/%s" % [id, version]
	var pck := ProjectSettings.globalize_path(ROOT.path_join(id + ".pck"))
	var packer := PCKPacker.new()
	packer.pck_start(pck)
	for rel in ["game.yml", "scripts/module.gd", "net/bridge.gd", "net/uses_bridge.gd", "net/extends_bridge.gd"]:
		packer.add_file(at.path_join(rel), ProjectSettings.globalize_path(src.path_join(rel)))
	packer.flush()
	_check("the fixture pack mounts", ProjectSettings.load_resource_pack(pck, false))
	return at


func _check(label: String, ok: bool) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", label])
	if not ok:
		_fails += 1
