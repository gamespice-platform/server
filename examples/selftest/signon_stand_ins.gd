extends RefCounted
## GameSpice Auth stand-ins for signon_revision: the halves GameSpice Server asks of GameSpice Auth, and what they saw.


## GameSpice Auth's client half for tickets: records what it was asked by.
class _TicketStandIn extends RefCounted:
	const TICKET := "ticket-for-the-test"
	var addresses: Array[String] = []
	var ids: Array[String] = []
	var nonces: Array[String] = []

	func request_ticket_for_address(address: String, _issuer := "", nonce := "") -> GSResult:
		addresses.append(address)
		nonces.append(nonce)
		return GSResult.success(TICKET)

	func request_ticket(_issuer: String, server_id: String) -> GSResult:
		ids.append(server_id)
		return GSResult.success(TICKET)


## GameSpice Auth's server half, as far as GameSpice Server asks: a strategy and a verdict.
class _AuthStandIn extends RefCounted:
	const AUDIENCE := "server:7"
	var on_authenticate: Callable
	var audience: String = AUDIENCE
	var strategy: String = "introspect"
	var nonces: Array[String] = []

	func strategy_name() -> String:
		return strategy

	func join_audience() -> String:
		return audience

	func authenticate(credential: Dictionary, _address: String, connection_nonce := "") -> GSResult:
		nonces.append(connection_nonce)
		on_authenticate.call(credential)
		return GSResult.fail(GSError.CODE_AUTH, "stand-in refuses everybody")


## Lets everybody in as the same account, for `sv_single_seat`.
class _SameAccountStandIn extends RefCounted:
	func strategy_name() -> String:
		return "local"

	func authenticate(_credential: Dictionary, _address: String, _nonce := "") -> GSResult:
		return GSResult.success(_Account.new())


class _Account extends RefCounted:
	var uid := "tmc:the-same-account"
	var display_name := "Twin"
	var is_guest := false


## GameSpice Auth's client half: an access token it must never send, and a join token
## minted only for a first-party audience.
class _TokenStandIn extends RefCounted:
	const SECRET := "bearer-secret-for-the-test"
	const JOIN := "tmc_jt_join-token-for-the-test"
	var minted_for: Array[String] = []
	var minted_at: Array[String] = []
	## Stands for GSAuthConfig: bind_join_address.
	var config := _BindConfig.new()

	func valid_access_token() -> GSResult:
		return GSResult.success(SECRET)

	func is_first_party(audience: String) -> bool:
		return audience == _AuthStandIn.AUDIENCE

	func request_join_token(audience: String, host: String = "", port: int = 0) -> GSResult:
		minted_for.append(audience)
		minted_at.append("%s:%d" % [host, port])
		return GSResult.success(JOIN)


class _BindConfig extends RefCounted:
	var bind_join_address := false
