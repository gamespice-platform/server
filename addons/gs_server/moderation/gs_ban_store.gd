@tool
class_name GSBanStore
extends Resource

## Where bans are kept. Subclass ([method _load], [method _put], [method _remove]) to share one
## list across servers via a database or HTTP service. Load may be slow, checks are not:
## [GSBanManager] answers joins from memory. Override [method _refresh] to poll for changes.

const CHANNEL := "bans.store"

## Seconds between [method refresh] calls; 0 disables polling. For a shared store, so a ban
## added elsewhere takes effect without a restart.
@export_range(0.0, 3600.0, 5.0) var refresh_interval_sec: float = 0.0



## Short name, for `banlist` output and logs.
func _store_name() -> String:
	return "custom"


## Loads every ban as [code]{key: ban_dictionary}[/code]; may be a coroutine. Called at
## startup and by [method refresh]. A failure must not mean "no bans": [GSBanManager] keeps
## what it had and logs, since an empty list readmits everyone removed.
func _load() -> GSResult:
	return GSResult.success({})


## Writes one ban. May be a coroutine.
func _put(_key: String, _ban: Dictionary) -> GSResult:
	return GSResult.fail(
		GSError.CODE_UNSUPPORTED, "%s is read-only." % _store_name()
	)


## Deletes one ban. May be a coroutine.
func _remove(_key: String) -> GSResult:
	return GSResult.fail(
		GSError.CODE_UNSUPPORTED, "%s is read-only." % _store_name()
	)


## Re-reads bans changed elsewhere; a full [method _load] by default. Override when the
## backing store can report a delta.
func _refresh() -> GSResult:
	return await _load()


## Whether this store accepts writes. False for a read-only mirror of a central list, so
## `ban` reports that rather than appearing to work.
func _writable() -> bool:
	return true



func store_name() -> String:
	return _store_name()


func writable() -> bool:
	return _writable()


func load_bans() -> GSResult:
	var result: Variant = await _load()

	if not (result is GSResult):
		return GSResult.fail(
			GSError.CODE_INTERNAL,
			"%s._load() returned something other than a GSResult." % _store_name()
		)

	var typed := result as GSResult

	if typed.ok and not (typed.value is Dictionary):
		return GSResult.fail(
			GSError.CODE_INTERNAL,
			"%s._load() must return a Dictionary of bans." % _store_name()
		)

	return typed


func put(key: String, ban: Dictionary) -> GSResult:
	if not _writable():
		return GSResult.fail(
			GSError.CODE_FORBIDDEN,
			"The ban store is read-only.",
			"bans are managed centrally; add it there"
		)
	var res: GSResult = await _put(key, ban)
	_report_write("a ban was not recorded", key, res)
	return res


func remove(key: String) -> GSResult:
	if not _writable():
		return GSResult.fail(
			GSError.CODE_FORBIDDEN, "The ban store is read-only."
		)
	var res: GSResult = await _remove(key)
	_report_write("a ban was not lifted", key, res)
	return res


## Logged here because every store's write passes through it. ERROR: a ban that did not reach a
## shared store is a player other servers still admit. Load and refresh failures are logged by
## GSBanManager, which knows whether the last good list applies.
func _report_write(what: String, key: String, res: GSResult) -> void:
	if res == null or res.ok:
		return
	GSLog.error(CHANNEL, what, {
		"store": _store_name(),
		"key": key,
		"code": res.code(),
		"error": res.error.message if res.error != null else "",
	})


func refresh() -> GSResult:
	return await _refresh()


func describe() -> Dictionary:
	return {
		"store": _store_name(),
		"writable": _writable(),
		"refresh_sec": refresh_interval_sec,
	}



## The default: a JSON file on this server. Correct for a single server; one server, one
## list, no sharing is why this class is abstract.
class FileStore extends GSBanStore:
	## Format version, so a future change can migrate rather than misread.
	const FORMAT_VERSION := 1

	var path: String

	func _init(p_path: String) -> void:
		path = p_path

	func _store_name() -> String:
		return "file"

	func _load() -> GSResult:
		if not FileAccess.file_exists(path):
			return GSResult.success({})

		var read := GSPaths.read_json(path)
		if not read.ok:
			return read.wrap("Could not read the ban list.")

		var data: Variant = read.value
		if not (data is Dictionary):
			return GSResult.fail(
				GSError.CODE_PARSE, "The ban list must be a JSON object."
			)

		var entries: Variant = (data as Dictionary).get("bans", {})
		if not (entries is Dictionary):
			return GSResult.success({})

		var out := {}
		for key in (entries as Dictionary):
			var ban: Variant = (entries as Dictionary)[key]
			if ban is Dictionary:
				out[str(key)] = ban

		return GSResult.success(out)

	## Writes the whole file ([method GSPaths.write_json] is atomic, so a crash leaves the
	## old list; the list is small enough that per-key writes would not pay).
	func write_all(bans: Dictionary) -> GSResult:
		return GSPaths.write_json(
			path, {"version": FORMAT_VERSION, "bans": bans}, false
		)

	func _put(_key: String, _ban: Dictionary) -> GSResult:
		# GSBanManager holds the authoritative in-memory set and calls write_all
		# after mutating it, so a per-key write here would be redundant.
		return GSResult.success(true)

	func _remove(_key: String) -> GSResult:
		return GSResult.success(true)
