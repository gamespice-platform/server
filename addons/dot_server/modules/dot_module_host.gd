@tool
class_name DotModuleHost
extends Node

## Loads, unloads and reloads [DotModule]s at runtime from [code]res://[/code] or [code]user://[/code].
## Reload re-instantiates; it cannot reclaim a mounted resource pack or undo changes a module made to the world.

const CHANNEL := "modules"
const SERVICE := &"dot_module_host"
const NOT_COMPILED := "Module script did not compile."

signal module_loaded(module: Node)  # a DotModule, typed Node so the host (reached from dot_server.gd) does not hold the module parser, which names DotServer
signal module_unloaded(module_name: String)

## Directories scanned by [method load_all], in order.
@export var search_dirs: PackedStringArray = PackedStringArray([
	"user://modules", "res://modules",
])

## Load everything in [member search_dirs] on setup.
@export var auto_load: bool = true

## Modules that must not be loaded, by name: disable a broken module without deleting its file and config.
@export var blocklist: PackedStringArray = PackedStringArray()

var server: Node = null  # a DotServer, held as Node so this file and dot_server.gd do not keep each other's parsers alive

## name -> DotModule
var _modules: Dictionary = {}

## name -> script path, so reload can find the source again.
var _paths: Dictionary = {}


## Wires the host to its server. Called by [DotServer].
func setup(p_server: Node) -> void:
	server = p_server
	DotRegistry.register(SERVICE, self)

	if server.games != null:
		server.games.game_loaded.connect(_on_game_changed)

	if auto_load:
		# Not awaited, and cannot be: `setup` runs from [DotServer]'s boot coroutine. A module that
		# suspends during a scan-load finishes on a later frame; `load_module` itself awaits the module.
		load_all()


func _exit_tree() -> void:
	unload_all()
	DotRegistry.unregister_instance(SERVICE, self)



## Loads every module script in the search directories (in an export, their remapped compiled forms).
func load_all() -> int:
	var loaded_count := 0

	for dir in search_dirs:
		if not DirAccess.dir_exists_absolute(dir):
			continue

		var seen := {}
		for rel in DotPaths.list_files_recursive(dir):
			var script_rel := module_script_of(rel)
			if script_rel == "" or seen.has(script_rel):
				continue
			seen[script_rel] = true

			var res: DotResult = await load_module(dir.path_join(script_rel))
			if res.ok:
				loaded_count += 1

	if loaded_count > 0:
		DotLog.info(CHANNEL, "modules loaded", {"count": loaded_count})

	return loaded_count


## The [code].gd[/code] path a listed file stands for, or "" when it is not a script.
## An export lists [code]x.gd.remap[/code] and [code]x.gdc[/code] where the source had [code]x.gd[/code].
static func module_script_of(file: String) -> String:
	if file.ends_with(".gd.remap"):
		return file.trim_suffix(".remap")
	if file.ends_with(".gdc"):
		return file.trim_suffix(".gdc") + ".gd"
	return file if file.ends_with(".gd") else ""


## True when [param path] can be loaded as a script: a source file, or in an export its remapped compiled form.
static func module_script_exists(path: String) -> bool:
	return FileAccess.file_exists(path) or ResourceLoader.exists(path)


## Loads the script at [param path] and makes the [DotModule] it declares.
func _instantiate_module(path: String) -> DotResult:
	if not module_script_exists(path):
		return DotResult.fail(
			DotError.CODE_IO, "Module script not found.", path
		)

	var script := load(path)
	if not (script is GDScript):
		return DotResult.fail(
			DotError.CODE_INVALID, "Not a GDScript file.", path
		)

	# `load()` returns a GDScript even when it did not parse, and `.new()` on it aborts this coroutine.
	if not (script as GDScript).can_instantiate():
		return DotResult.fail(
			DotError.CODE_INVALID,
			NOT_COMPILED,
			path
		)

	var instance: Variant = (script as GDScript).new()

	if not _is_module(instance):
		# A Node never added to the tree leaks until the process ends.
		if instance is Node:
			(instance as Node).queue_free()
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A module script must extend DotModule.",
			path
		)

	return DotResult.success(instance)


## Where a module's scripts live: a delivered pack's mount (res://dot_cloud/owner/id/version), else the
## nearest directory up holding a game.yml, else the module's own directory.
static func module_root_of(path: String) -> String:
	const PACKS := "res://dot_cloud/"
	if path.begins_with(PACKS):
		var parts := path.trim_prefix(PACKS).split("/")
		if parts.size() > 3:
			return PACKS + "/".join(parts.slice(0, 3))
	var dir := path.get_base_dir()
	var d := dir
	while d != "res://" and d != "user://" and d != "":
		if FileAccess.file_exists(d.path_join("game.yml")):
			return d
		var up := d.get_base_dir()
		if up == d:
			break
		d = up
	return dir


## A failed module load, with the script errors under the module's root added to its message.
## Without them the log carries only what the module concluded ("A game has to supply the bridge
## ...") while the cause, a script of the game that no longer compiles against the installed
## addons, was printed once, earlier, among the boot output. [param known_cause] is true when the
## module script itself did not compile, so a broken script is the cause; for a module that refused
## on its own the broken scripts are listed as found, not as the cause (a client-only or tool
## script may be broken without being why the module refused).
static func with_script_errors(failed: DotResult, path: String, known_cause := true) -> DotResult:
	if failed.ok:
		return failed
	var errors := script_errors_under(module_root_of(path))
	if errors.is_empty():
		return failed
	var code := failed.error.code if failed.error != null else DotError.CODE_INTERNAL
	var message := failed.error.message if failed.error != null else "The module did not load."
	var detail := failed.error.detail if failed.error != null else path
	var what := "a script that does not compile" if errors.size() == 1 else "%d scripts that do not compile" % errors.size()
	var e := DotError.make(
		code,
		("%s Caused by %s: %s" if known_cause else "%s The game has %s: %s") % [message, what, " | ".join(errors)],
		detail
	)
	if failed.error != null:
		e.context = failed.error.context
	return DotResult.failure(e)


## One line per script under [param root] that does not compile, naming its first own error as
## "file:line: Parse Error: ..." (path relative to the root). A script that fails only because a
## script it depends on failed is listed after the ones with errors of their own.
static func script_errors_under(root: String) -> PackedStringArray:
	var files := PackedStringArray()
	for rel in DotPaths.list_files_recursive(root):
		var found := module_script_of(rel)
		if found != "" and not rel.begins_with(".") and not files.has(root.path_join(found)):
			files.append(root.path_join(found))
	files.sort()

	var broken := PackedStringArray()
	for f in files:
		var s: Variant = load(f)
		if not (s is GDScript and (s as GDScript).can_instantiate()):
			broken.append(f)
	if broken.is_empty():
		return broken

	# A loaded script does not keep its errors, so each broken one is parsed again, uncached, with
	# the engine's error stream captured.
	var own := PackedStringArray()
	var follow_on := PackedStringArray()
	for f in broken:
		var capture := _ScriptErrorCapture.new()
		OS.add_logger(capture)
		ResourceLoader.load(f, "", ResourceLoader.CACHE_MODE_IGNORE)
		OS.remove_logger(capture)
		var rel := f.trim_prefix(root + "/")
		var first := capture.first_own_error().replace(root + "/", "")
		if first != "":
			own.append(first)
		else:
			var any := capture.first_error().replace(root + "/", "")
			follow_on.append("%s does not compile%s" % [rel, (": " + any) if any != "" else ""])
	own.append_array(follow_on)
	return own


## Collects the script errors the engine reports while it is installed. Called from any thread.
class _ScriptErrorCapture extends Logger:
	const FOLLOW_ON := ["Could not resolve", "depended", "Could not preload", "Could not load", "Failed to load"]

	var _lock := Mutex.new()
	var _errors: PackedStringArray = []

	func _log_error(
		_function: String, file: String, line: int, code: String, rationale: String,
		_editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]
	) -> void:
		if error_type != ERROR_TYPE_SCRIPT:
			return
		var text := code if rationale == "" else "%s %s" % [code, rationale]
		_lock.lock()
		_errors.append("%s:%d: %s" % [file, line, text.strip_edges()])
		_lock.unlock()

	func first_error() -> String:
		_lock.lock()
		var e := "" if _errors.is_empty() else _errors[0]
		_lock.unlock()
		return e

	func first_own_error() -> String:
		_lock.lock()
		var found := ""
		for e in _errors:
			var cascade := false
			for marker in FOLLOW_ON:
				if e.contains(marker):
					cascade = true
					break
			if not cascade:
				found = e
				break
		_lock.unlock()
		return found


## Loads one module from a script path.
func load_module(path: String) -> DotResult:
	var made := _instantiate_module(path)
	if not made.ok:
		# Only a compile failure has a cause worth the scan; "must extend DotModule" says it all.
		if made.error != null and made.error.message == NOT_COMPILED:
			return with_script_errors(made, path)
		return made

	var module: Node = made.value  # a DotModule (see _is_module)
	var module_name: String = module._module_name()

	if blocklist.has(module_name):
		module.queue_free()
		DotLog.info(CHANNEL, "module blocked", {"module": module_name})
		return DotResult.fail(
			DotError.CODE_FORBIDDEN, "Module is blocklisted.", module_name
		)

	if _modules.has(module_name):
		module.queue_free()
		return DotResult.fail(
			DotError.CODE_STATE,
			"A module named '%s' is already loaded." % module_name
		)

	module.name = "Module_" + module_name
	module.server = server
	module.console = server.console
	module.events = server.events

	add_child(module)

	# Awaited: `_module_load` may suspend, and an un-awaited coroutine hands back null at its first
	# suspension. `await` passes a synchronous module's value straight through.
	# Typed explicitly, because `await` yields a Variant and `:=` would widen `result`.
	var result: DotResult = await module._module_load()

	if result == null:
		result = DotResult.fail(DotError.CODE_INTERNAL, "_module_load() returned no result.", path)

	if not result.ok:
		result = with_script_errors(result, path, false)
		# A module that refused to load must not stay half-attached: its partial
		# registrations would fire into an object that believes it is not running.
		DotLog.error(
			CHANNEL,
			"module refused to load",
			{"module": module_name, "why": str(result.error)}
		)
		module._cleanup_registrations()
		module.queue_free()
		return result

	module.loaded = true
	_modules[module_name] = module
	_paths[module_name] = path

	DotLog.info(
		CHANNEL,
		"module loaded",
		{
			"module": module_name,
			"version": module._module_version(),
			# `get`, not `[]`: an overridden describe() without this key would throw inside the log call.
			"commands": module.describe().get("commands", 0),
		}
	)

	module_loaded.emit(module)
	return DotResult.success(module)



func unload_module(module_name: String) -> DotResult:
	if not _modules.has(module_name):
		return DotResult.fail(
			DotError.CODE_INVALID, "No module named '%s'." % module_name
		)

	var module: Node = _modules[module_name]

	# Teardown runs first, while registrations still exist. `_module_unload` must be SYNCHRONOUS:
	# `unload_all` runs from `_exit_tree`, with no frame left to resume a coroutine. A coroutine that
	# suspends returns a [Signal], detected via `call` (a `-> void` return cannot be read directly).
	var teardown: Variant = module.call("_module_unload")

	if teardown is Signal:
		push_error(
			"%s._module_unload() suspended. Module teardown must be synchronous: "
			% module_name
			+ "unloading runs during shutdown, where there is no frame to resume in."
		)
	module._cleanup_registrations()

	# Belt and braces: a module that hooked directly rather than through the
	# helpers would otherwise leave hooks pointing at a freed object.
	if server.events != null:
		server.events.unhook_all(module)

	_modules.erase(module_name)
	_paths.erase(module_name)

	module.queue_free()

	DotLog.info(CHANNEL, "module unloaded", {"module": module_name})
	module_unloaded.emit(module_name)

	return DotResult.success(module_name)


func unload_all() -> int:
	var names := loaded_names()
	for module_name in names:
		unload_module(module_name)
	return names.size()


## Unloads and loads a module again from the same path.
func reload_module(module_name: String) -> DotResult:
	if not _paths.has(module_name):
		return DotResult.fail(
			DotError.CODE_INVALID, "No module named '%s'." % module_name
		)

	var path := str(_paths[module_name])

	var unloaded := unload_module(module_name)  # synchronous; see unload_module
	if not unloaded.ok:
		return unloaded

	# The engine caches scripts by path, so a file edited on disk would reload as
	# the old version without this.
	var cached := ResourceLoader.exists(path)
	if cached:
		var script := load(path)
		if script is GDScript:
			(script as GDScript).reload()

	return await load_module(path)



func get_module(module_name: String) -> Node:  # a DotModule
	return _modules.get(module_name)


func has_module(module_name: String) -> bool:
	return _modules.has(module_name)


func loaded_names() -> PackedStringArray:
	var out := PackedStringArray(_modules.keys())
	out.sort()
	return out


func count() -> int:
	return _modules.size()


func _on_game_changed(content_key: String) -> void:
	for module_name in _modules:
		_modules[module_name]._module_game_changed(content_key)


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	if _modules.is_empty():
		out.append("no modules loaded")
		return out

	for module_name in loaded_names():
		var module: Node = _modules[module_name]
		out.append("%-20s %-10s %s" % [
			module_name,
			module._module_version(),
			module._module_description(),
		])

	return out


# True when [param instance] is a [DotModule]. The module script is loaded here (once per module load) and its
# instances are held as Node, so this host, which dot_server.gd names, does not keep the DotModule parser (which
# names DotServer) alive in a cycle.
static func _is_module(instance: Variant) -> bool:
	if not (instance is Object):
		return false
	var want: Script = load("uid://dgwlrdlk67gwp")
	var s: Script = (instance as Object).get_script()
	while s != null:
		if s == want:
			return true
		s = s.get_base_script()
	return false
