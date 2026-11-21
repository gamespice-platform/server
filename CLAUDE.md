# GameSpice Server

Dedicated server framework for Godot 4: console variables and commands, RCON, flag-based admin permissions, moderation, votes, a game event bus, hot-loadable modules, and switching games while players stay connected. Every game in the family runs on it, and `GSClientLink` is the client half every shell uses.

**The distributable is `addons/gs_server/`.** It requires [GameSpice Core](../gs-core) and optionally integrates with gs-auth, gs-cloud, gs-moderation, gs-chat and gs-server-query, all discovered at runtime, none imported.

```bash
ln -s ../../gs-core/addons/gs_core addons/gs_core
# Optional; the self-test runs the ban-source seam against a real gs-moderation and says so loudly when the link is missing.
ln -s ../../gs-moderation/addons/gs_moderation addons/gs_moderation
```

Read the family [CLAUDE.md](../../CLAUDE.md) first; this file is only what is specific to gs-server. The reasoning is in [docs/](docs/README.md).

## Read before

| Read | Before |
| --- | --- |
| [docs/README.md](docs/README.md) | the index |
| [docs/boot.md](docs/boot.md) | boot order, `server.cfg`, startup-only cvars, hibernation, `sv_tickrate` |
| [docs/signon.md](docs/signon.md) | anything on the join path, `GSClientLink`, `GSEnvelope`, `GSSignon`, heartbeats, the metered peer |
| [docs/transports.md](docs/transports.md) | `transport_mode`, ENet, the shared UDP port, credentials |
| [docs/game-facing.md](docs/game-facing.md) | `GSNotice`, the scoreboard, chat state, `GSBotQuota` |
| [docs/console.md](docs/console.md) | a command or cvar, chat commands, `add_source`, completion, modules, target names |
| [docs/security.md](docs/security.md) | permissions, RCON, sanitising, bans, `gs_ban_source`, the per-address limit |
| [docs/game-switching.md](docs/game-switching.md) | `GSGameManager`, descriptors, delivered content, an optional addon, the query hook |
| [docs/testing.md](docs/testing.md) | the four suites |
| [docs/history.md](docs/history.md) | a server bug that "cannot be happening" |

## Layout

| Path | What |
| --- | --- |
| `addons/gs_server/gs_server_api.gd` | the API level and what each level added |
| `console/` | `gs_convar.gd` (values as strings, flags enforced here), `gs_concommand.gd`, `gs_cmd_context.gd` (who is calling), `gs_console.gd` (registry, buffer, cfg, completion, `add_source`), `gs_builtin_commands.gd` (the whole command surface) |
| `server/` | `gs_server_config.gd` (boot config; `validate()`), `gs_client_session.gd` (the signon state machine: read it), `gs_guest_identity.gd`, `gs_server.gd` (lifecycle, sessions, the six envelope RPCs, timeouts, tick, notices, scoreboard) |
| `client/` | `gs_client_link.gd` (the client's half: the same six RPCs, the other ends' kinds), `gs_client_chat.gd` (declares no RPC) |
| `net/` | `gs_envelope.gd` (kinds, adverts, required/optional, the refusal sentence), `gs_signon.gd` (the six RPC names as twelve characters), `gs_notice.gd` |
| `admin/` | `gs_admin_flags.gd`, `gs_admin_manager.gd` (resolution, merging, sources) |
| `moderation/` | `gs_ban_manager.gd`, `gs_address_guard.gd`, `gs_audit_log.gd` (JSONL, flushed per entry) |
| `rcon/` | `gs_rcon_server.gd` (classic RCON plus WebSocket) |
| `chat/` | `gs_chat_manager.gd` (routing, flood control, sanitising, chat triggers) |
| `game/` | `gs_game_descriptor.gd` (scene paths resolve under the mount prefix), `gs_game_manager.gd` (the change flow) |
| `vote/`, `events/` | `gs_vote_manager.gd`; `gs_event.gd` (pre-hooks may rewrite or cancel), `gs_event_bus.gd` |
| `modules/` | `gs_module.gd` (base class; the helpers are not optional), `gs_module_host.gd`, `gs_bot_quota.gd` |
| `cfg/` | `server.cfg` (shipped defaults; copy to `user://cfg` and edit that), `autoexec.cfg` |
| `examples/` | `dedicated_server`, `signon_revision`, `content_switch`, `mixed_transports` |
| `examples/cfg_selftest.tscn` | `groups.yml` and `permissions.yml` through `GSAdminCfg`: `cfg/addons/gs_server/`, `cfg/server/addons/gs_server/` over it, the flat `cfg/<file>.yml` shim (WARN once, removed 2026-12-31) |

## Running and testing

The family's two steps ([family CLAUDE.md](../../CLAUDE.md#validating-anything)), then `dedicated_server.tscn`, `signon_revision.tscn`, `content_switch.tscn` and `mixed_transports.tscn`. `dedicated_server.tscn -- --serve` runs a real server. **A change here is not done until gs-server-deploy's `*_client` suites and the games' net suites agree.** [testing](docs/testing.md)

## API level

`LEVEL` in `addons/gs_server/gs_server_api.gd` (no `class_name`) rises by one for anything a game could call that did not exist before; `OLDEST` is raised to `LEVEL` when something a game could call is removed or changes meaning. The rule is GameSpice Core's `GSAddonApi`; packs declare what they need in `requires.json` and a server refuses one it cannot run. Write the new level's additions in the file's comment. Current levels: 2 descriptor pack lists, 3 dual transport, 4 the scoreboard roster, 5 `GSBotQuota` / `addon_set` / `rtt_ms()`, 6 `net_meter()` and the heartbeat ack's `"sv"`, 7 the `PROFILE` signon stage (`hold_profile` / `release_profile` / `refuse_profile`, `profile_timeout_sec`), 8 replicated cvars (`GSEnvelope.CVARS`, `GSClientLink.replicated_cvar()`), 9 the block list's roster (`"key"` and `"peer"` on scoreboard rows, `GSServer.player_key()`, `GSClientLink.request_scoreboard()`), 10 `GSClientLink.tls_connect_timeout_sec` (a native WebSocket join to a public bare `host:port` tries `wss://` first), 11 the thread settings (`worker_threads`, `threads_net`, `threads_npc` as `sv_worker_threads` / `sv_threads_net` / `sv_threads_npc`, `net_snapshot_workers()`, `describe_threads()`), 12 `GSAdminCfg.load_groups` / `load_users` (the yml layout, `cfg/addons/gs_server/`), 13 the challenge's `ticket_nonce` passed to GameSpice Auth's `authenticate` (connection-bound tickets) and `sv_single_seat`, 14 `net_native` (`GSServerConfig.net_native`), 15 `net_native_interest`, 18 module scripts resolve in exports (`GSModuleHost.module_script_exists`), 20 `worker_threads_auto_max` (`sv_worker_threads_auto_max`, default 8, 0 = no cap) and `resolved_workers()`. 21 `GSConVar` refuses an out-of-range value with the reason instead of clamping (`range_text()`; `sv_tickrate_tiers` refuses a rate under 15), 22 no hard caps: `sv_scoreboard_max_rows` (default 1024, 0 = unlimited), `GSEventBus.max_events_per_frame` and `GSClientLink` replicated-cvar limits take 0 = unlimited, 23 `sv_max_ping_report` (default 60000, 0 = unlimited), 24 envelope, RCON, notice and immunity limits are settings (`sv_envelope_max_kinds`, `sv_rcon_max_packet_bytes`, `sv_notice_max_text`, `sv_max_immunity`, `GSServer.apply_limit_cvars()`; over-limit input is refused or cut with a `GSLog.error` naming the setting).

## Rules that bite

**The wire**

- `GSServer` and `GSClientLink` declare exactly six `@rpc` methods and nothing else here may declare any. A new feature is a new envelope kind, never an `@rpc`. [signon](docs/signon.md#the-rpc-surface-is-frozen-dotenvelope)
- Payloads change only by adding a field, read through `GSEnvelope.number`/`text`/`flag`; a change that cannot be an addition is a new kind. [signon](docs/signon.md#the-rpc-surface-is-frozen-dotenvelope)
- Only core join kinds are required; a feature kind is optional so an older peer loses the feature and keeps the game. [signon](docs/signon.md#the-rpc-surface-is-frozen-dotenvelope)
- The signon revision is derived from the RPC names, never written by hand; an empty revision is never a mismatch. [signon](docs/signon.md#the-signon-revision-dotsignon)
- A hidden browser tab announces itself reliably and flushes its own peer; the grace is the server's number. [signon](docs/signon.md#a-browser-tab-that-is-not-on-screen-is-not-running)
- `GSClientSession.State` values never move: a new stage goes on the end of the enum, the order is `_can_transition`'s. [signon](docs/signon.md#the-join-state-machine)
- A module holds `PROFILE` from inside `client_state_changed`, before any await; nobody holding means the player goes straight through. [signon](docs/signon.md#the-profile-stage-a-module-may-hold-a-player-and-refuse-them-unseen)
- No bearer secret (access token, account password) is ever sent over ENet; tickets and the server's own join password are. [transports](docs/transports.md)
- `FLAG_REPLICATED` cvars reach clients (`GSEnvelope.CVARS`, table before each `LOAD_GAME`, deltas after); never replicate a protected one. [game-facing](docs/game-facing.md#replicated-cvars-the-servers-rules-on-the-client)
- Ask a peer list before sending to a session; a session with no peer is an engine error per send. [game-facing](docs/game-facing.md#gsnotice-something-for-the-hud-that-is-not-chat)

**Boot and time**

- `server.cfg` runs before the listener and is the only file where a startup-only cvar works; argv's cvar half runs before the listener too. [boot](docs/boot.md#boot-order-is-fixed-and-load-bearing)
- A created subsystem has run `_ready()` before its config is set; trigger loads explicitly. [boot](docs/boot.md#boot-order-is-fixed-and-load-bearing)
- `sv_tickrate` set while running waits for `apply_pending_tickrate()` or the next game change; `tickrate()` is never the hibernation rate. [boot](docs/boot.md#sv_tickrate-is-live-and-applies-at-a-boundary)
- An empty server hibernates from boot; "up" is `RUNNING or HIBERNATING`; clocks follow `hibernation_changed`. [boot](docs/boot.md#hibernation-an-empty-server-is-idle-and-its-clocks-wait)
- A game load wakes the server, and it sleeps again deferred. A one-process server+client test turns hibernation off. [boot](docs/boot.md#a-game-loads-awake)

**Console and modules**

- Every path in goes through `GSConsole.execute` with a `GSCmdContext`; the permission flag is the boundary, not the source. [console](docs/console.md#console-design)
- Modules register through `GSModule`'s helpers, or an unload leaves handlers on a freed object. [console](docs/console.md#modules)
- Descriptor cvars apply in two passes; a host calls `reapply_descriptor_cvars()` once its module is up. [console](docs/console.md#modules)
- `map` is GameSpice Map's; this addon switches games (`changelevel`, `game`). [console](docs/console.md#map-belongs-to-gs-map)
- A lambda held by a long-lived console can outlive its script at teardown; use static methods for validators. [game-facing](docs/game-facing.md#how-many-bots-dotbotquota)
- Never leave a thread blocked in `read_string_from_stdin` at exit: it holds stdio's lock and the process hangs (a panel never sees exit 75). On Linux a `cat` helper feeds a file; a thread is only for a file or no shell. A GDScript frame on a reader thread made `quit` exit 139. Run `examples/exit_code_check.sh` (pipe and pty must exit 75). [testing](docs/testing.md)

**Security and moderation**

- Empty `rcon_password` means no listener; passwords compare in constant time; the allow-list is checked before the password. [security](docs/security.md#security-decisions-worth-not-undoing)
- `_resolve_scene` refuses absolute paths outside the mount; the client `ensure`s, never `acquire`s, server-named content. [security](docs/security.md#security-decisions-worth-not-undoing)
- A malformed `admins.json`/`bans.json` keeps the previous state; a failed ban-store load keeps what is in force. [security](docs/security.md)
- `gs_ban_source` is read-only and asked twice per join; a source that cannot answer is reported once and ignored. [security](docs/security.md#somebody-elses-ban-list-gs_ban_source)
- `await bans.unban(x).ok` binds to the property: assign the result first. [security](docs/security.md#sharing-a-ban-list-across-servers)
- `ip:` matches a household; acting on it checks immunity against every session there. [console](docs/console.md#naming-a-player)

**Games and content**

- Never name an optional addon's class here; reach it through `GSRegistry` or `Object.call`. [game-switching](docs/game-switching.md#coupling-nothing-is-imported)
- The server acquires the new content before telling clients; during a sync the current game is still the old one. [game-switching](docs/game-switching.md#the-change-flow)
- A built-in game has no client scene (`""`); delivered is `needs_delivered_content()`, not a `manifest_url`. [game-switching](docs/game-switching.md#delivered-or-shipped-in-the-build)
- The query config stays on `GSServerConfig` even though the responder is GameSpice Server Query's. [game-switching](docs/game-switching.md#server-queries-live-in-gs-server-query)
- What a game parents under `Server` (its RPC link) is retired at the change on both ends: renamed at once, freed 10 s later. Nothing but a game adds children under `GSServer` after boot. [game-switching](docs/game-switching.md#what-a-game-parents-under-server-goes-with-the-game)

## Things deliberately not here

- **Serving content in-band.** GameSpice Cloud's `GSCloudSourceNetchan` expects a server exposing `cloud_chunk_size()` / `cloud_request_chunk()`; nothing here does. `allow_netchan_content`, `netchan_chunk_bytes` and `netchan_chunks_per_second` are declared, sent to clients and enforced by nothing; when it lands, the rate limit is the security control.
- **State replication.** GameSpice Server gets a player into the world and hands over; snapshots, prediction and lag compensation are a game's (GameSpice Net). `GSTransport.Channel.STATE` is reserved for it.
- **A master-server heartbeat.** `sv_lan` exists and does nothing yet; a tracker has to be told the address.
- **Answering a query.** GameSpice Server Query does that, and GameSpice Browser asks.
- **A listen-server helper.** `GSServer` and `GSClientLink` in one process works (that is why there are no autoloads), but nothing wraps the pattern.
