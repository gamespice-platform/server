@tool
extends "res://addons/dot_server/client/dot_client_link_connect.gd"

## The challenge, credentials and content sync of [GSClientLink].


## Refuses a server whose RPC set or protocol differs: Godot would silently drop every
## message after the first, which the player sees as a spinner and "Timed out".
func _revision_compatible(challenge: Dictionary) -> bool:
	var ours := GSSignon.revision([load("uid://bbnmrseos3avj")])  # GSClientLink, loaded: this file is one of its bases
	var theirs := str(challenge.get("signon", ""))

	# Kept before the refusal so a shell can tell the page which build the server wants.
	server_signon = theirs

	if not GSSignon.compatible(ours, theirs):
		var mismatch := GSSignon.explain(ours, theirs)
		GSLog.error(CHANNEL, "signon revision mismatch", {
			"server": theirs, "client": ours, "host": server_hostname
		})
		_fail(mismatch)
		disconnect_from_server(mismatch.message)
		return false

	# A kind that kept its name and changed its meaning; see [constant GSSignon.PROTOCOL].
	var protocol := int(GSEnvelope.number(challenge, "protocol", GSSignon.PROTOCOL))
	if protocol != GSSignon.PROTOCOL:
		var differs := GSSignon.explain_protocol(GSSignon.PROTOCOL, protocol)
		GSLog.error(CHANNEL, "signon protocol mismatch", {
			"server": protocol, "client": GSSignon.PROTOCOL, "host": server_hostname
		})
		_fail(differs)
		disconnect_from_server(differs.message)
		return false
	return true


## The server asking us to identify ourselves.
func _on_challenge(_peer_id: int, challenge: Dictionary) -> void:
	server_hostname = str(challenge.get("hostname", ""))
	server_id = str(challenge.get("server_id", ""))
	server_join_audience = str(challenge.get("join_audience", ""))
	_ticket_nonce = str(challenge.get("ticket_nonce", ""))
	var addons: Variant = challenge.get("addons", [])
	server_addons = (addons as Array).duplicate(true) if addons is Array else []

	# Where those addons are published, for a client with no content origin of its own
	# yet (see `GSServer._handshake_challenge`). The same adoption `content.sync` does.
	if challenge.has("content_base_urls"):
		var cloud := GSRegistry.get_service(cloud_service)
		if cloud != null:
			_adopt_content_bases(cloud, challenge.get("content_base_urls"))

	if not _revision_compatible(challenge):
		return

	# What the server knows, so nothing it has never heard of is sent to it. Not refused
	# here: the server compares both adverts at the credentials and refuses in words.
	var adopted := envelope.adopt(1, challenge.get("kinds"), false)
	if not adopted.ok:
		GSLog.debug(CHANNEL, "the server's kinds do not cover this client's", {
			"why": adopted.error.message, "detail": adopted.error.detail,
		})

	# Challenged: whatever fails after this is reported against its own stage.
	if _signon_watchdog != null:
		_signon_watchdog.stop()

	server_info.emit(challenge)

	GSLog.info(
		CHANNEL,
		"server challenge",
		{
			"hostname": server_hostname,
			"auth": str(challenge.get("auth", "none")),
			"password": bool(challenge.get("needs_password", false)),
		}
	)

	var payload := {
		"name": player_name,
		# Stable per install, so a guest can be muted or kicked for a session
		# without anything that survives a reinstall.
		"device_id": Credentials.device_id(),
		# What this client can say and hear. The server decides from it whether the two
		# can play; see [GSEnvelope].
		"kinds": envelope.advert(),
		# What kind of client this is, so a server whose owner has turned a platform
		# off can say so in a sentence. A payload field, not an RPC: the signon
		# revision does not move, and a server from before this ignores it.
		"platform": platform_kind(),
	}

	if bool(challenge.get("needs_password", false)):
		payload["password"] = _password

	var strategy := str(challenge.get("auth", "none")).to_lower()
	if not _may_send_credential_here(strategy):
		return
	if not await _creds.attach_credential(payload, strategy):
		return

	send_kind(GSEnvelope.CREDENTIALS, payload)


## Whether this link's transport may carry the credential [param strategy] needs.
## ENet is not encrypted: a ticket is safe in the clear (single-use, short, one server) but an access token or password is a bearer secret.
## Those never go over UDP: the link rejoins over WebSocket (TLS under wss://). The server's shared join password is sent as ever.
func _may_send_credential_here(strategy: String) -> bool:
	if transport_used != "enet" or not strategy in ["introspect", "local"]:
		return true

	if transport_preference == "udp":
		_fail(GSError.make(
			GSError.CODE_UNSUPPORTED,
			"This server's sign-in cannot be sent over UDP.",
			"strategy %s sends a secret and UDP is unencrypted; connect over WebSocket" % strategy
		))
		disconnect_from_server()
		return false

	GSLog.info(
		CHANNEL,
		"this server's sign-in sends a secret and UDP is unencrypted; rejoining over WebSocket",
		{"strategy": strategy}
	)
	_rejoin_over_websocket.call_deferred()
	return false


## `web`, `mobile` or `desktop`: the class of client, which is a policy fact an owner
## chooses by, not a capability -- so it is the one place the family asks about the
## platform itself rather than about what it can do.
static func platform_kind() -> String:
	if OS.has_feature("web"):
		return "web"
	if OS.has_feature("mobile"):
		return "mobile"
	return "desktop"


func _rejoin_over_websocket() -> void:
	_secure_rejoin = true
	disconnect_from_server()
	await connect_to_server(_last_address, _password)
	_secure_rejoin = false


## Connects once, keeping the Callable: a fresh lambda never matched `is_connected`, so every
## game change added another subscriber and the server got one progress RPC per copy.
func _watch_cloud_progress(cloud: Object) -> void:
	if not cloud.has_signal("progress_changed"):
		return
	if _progress_handler.is_null():
		_progress_handler = _on_cloud_progress
	if not cloud.is_connected("progress_changed", _progress_handler):
		cloud.connect("progress_changed", _progress_handler)


## Fetches the packs the game needs beside its own (maps, shared assets), by id and version,
## before `content.ready`. False when one failed; the link has already failed.
func _ensure_extra_content(cloud: Object, info: Dictionary) -> bool:
	content_extra = PackedStringArray()
	for extra in info.get("content_extra", []):
		content_extra.append(str(extra))

	for extra in info.get("content_extra", []):
		var key := str(extra)
		var at := key.rfind("@")
		var dep_id := key.substr(0, at) if at > 0 else key
		var dep_version := key.substr(at + 1) if at > 0 else ""

		if dep_id == "" or dep_version == "":
			_fail(GSError.make(
				GSError.CODE_INVALID,
				"This server named a dependency without a version: %s" % key
			))
			return false

		var got: Variant = await cloud.call("ensure", dep_id, dep_version)

		if not (got is GSResult) or not (got as GSResult).ok:
			var why := (got as GSResult).error if got is GSResult else GSError.make(
				GSError.CODE_INTERNAL, "Content download failed."
			)
			_fail(GSError.make(
				why.code,
				"This game needs %s, which could not be downloaded." % key,
				str(why)
			))
			return false
	return true


## The server telling us to fetch content before we can play.
func _on_content_sync(_peer_id: int, info: Dictionary) -> void:
	var manifest_url := str(info.get("manifest_url", ""))
	var content_key := str(info.get("content_key", ""))

	_set_phase(Phase.DOWNLOADING, "Downloading game content…")

	var cloud := GSRegistry.get_service(cloud_service)

	if cloud == null:
		# Pretending to be ready would put the player in a world of missing assets.
		GSLog.error(
			CHANNEL,
			"this server requires downloadable content but dot-cloud is not installed"
		)
		_fail(GSError.make(
			GSError.CODE_UNSUPPORTED,
			"This server needs downloadable content, which this build cannot fetch."
		))
		return

	_watch_cloud_progress(cloud)

	_adopt_content_bases(cloud, info.get("content_base_urls", []))

	GSLog.info(
		CHANNEL, "syncing content", {"content": content_key, "url": manifest_url}
	)

	var groups := PackedStringArray()
	for group in info.get("content_groups", []):
		groups.append(str(group))

	# By id and version, the URL only an override: `ensure` refuses a manifest answering to
	# another id or version, so a server cannot make the client mount a pack it never asked for.
	var parts := content_key.split("@", true, 1)
	var want_id := parts[0] if parts.size() > 0 else ""
	var want_version := parts[1] if parts.size() > 1 else ""

	if want_id == "":
		# A URL with no content key is old or broken; mounting blind is what `ensure` prevents.
		_fail(GSError.make(
			GSError.CODE_INVALID,
			"This server asked for content without saying what it is."
		))
		return

	var res: Variant = await cloud.call(
		"ensure", want_id, want_version, groups, manifest_url
	)

	if not (res is GSResult) or not (res as GSResult).ok:
		var err := (res as GSResult).error if res is GSResult else GSError.make(
			GSError.CODE_INTERNAL, "Content download failed."
		)
		_fail(err)
		return

	if not await _ensure_extra_content(cloud, info):
		return

	send_kind(GSEnvelope.CONTENT_READY, {"content_key": content_key})


## Adds the server's content addresses after the client's own (a LAN mirror still wins). Only
## somewhere to ask: the manifest must still carry a signature from a key the client holds.
## Duck-typed, since GameSpice Server does not depend on GameSpice Cloud.
func _adopt_content_bases(cloud: Object, urls: Variant) -> void:
	# PackedStringArray is not an Array: the packed arrays are their own Variant types, so an `is Array`
	# guard rejected exactly the value the config holds and the RPC carries, and the client silently
	# never learned the address.
	var list: Array = []
	if urls is PackedStringArray:
		list = Array(urls as PackedStringArray)
	elif urls is Array:
		list = urls as Array

	if list.is_empty():
		return
	if not (cloud.get("http_base_urls") is PackedStringArray):
		return

	var bases: PackedStringArray = cloud.get("http_base_urls")
	var added := PackedStringArray()

	for u in list:
		var one := str(u).strip_edges()
		# Re-sent on every game change, so without this the list grows by the same
		# addresses each time and every miss costs one more request than the last.
		if one != "" and not bases.has(one):
			bases.append(one)
			added.append(one)

	if added.is_empty():
		return

	cloud.set("http_base_urls", bases)
	GSLog.info(
		CHANNEL,
		"the server said where its content is",
		{"added": ", ".join(added)}
	)


func _on_cloud_progress(p: Dictionary) -> void:
	var fraction := float(p.get("fraction", 0.0))
	send_kind(GSEnvelope.CONTENT_PROGRESS, {"fraction": fraction})
	download_progress.emit(fraction, _progress_text(p))


static func _progress_text(p: Dictionary) -> String:
	var done := int(p.get("done_bytes", 0))
	var total := int(p.get("total_bytes", 0))
	if total <= 0:
		return "Downloading…"
	return "Downloading %s of %s" % [
		GSPaths.format_bytes(done), GSPaths.format_bytes(total)
	]
