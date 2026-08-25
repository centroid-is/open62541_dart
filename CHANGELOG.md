# Changelog

The version number tracks the bundled [open62541](https://github.com/open62541/open62541)
release, followed by a package revision suffix (`+1`, `+2`, ...) for Dart-side
changes that ship the same native library version.

## 1.5.7+2

- Root-cause fixes for the production frozen-client runaway (tfc-hmi#346
  bench, captured native stack): `UA_Client_run_iterate` performs synchronous
  multi-second selects during secured-channel handshakes, and a failed
  handshake leaks its half-open transport on every retry — enough leaked
  connections exhaust the server's connection pool and the client
  manufactures the server's "sickness".
  - `Client`/`ClientIsolate` gain `requestTimeout` (default **500ms**),
    applied to `UA_ClientConfig.timeout`: bounds the handshake selects (and
    service-call waits) so the event loop stays responsive. Raise it if a
    slow network legitimately needs more per call.
  - The `keepConnected` supervisor now **recreates the native client between
    reconnect attempts** — `UA_Client_delete` is what actually closes a
    transport left half-open by a failed handshake. Stream getters on
    `Client` (`stateStream` & co.) are now client-lifetime forwarders that
    keep emitting across the swap; active monitored-item streams get a
    `SecureChannelClosed` error so callers resubscribe.
  - `keepConnected` gains `handshakeTimeout` (default 10s), a
    **progress-aware** bound: the clock restarts on every observed
    channel/session/status change, so a slow-but-progressing secured
    handshake is never axed while one wedged in a single state (channel
    expired mid-session-create, HEL never ACKed, exhausted server pool) is
    abandoned and retried without any external watchdog.

- `ClientIsolate` self-heal: `keepConnected` gains `unresponsiveTimeout`. In
  production a dead secured (SignAndEncrypt) connection can wedge the client
  isolate inside a native call, after which the isolate stops answering
  messages entirely — state queries time out and even `disconnect` is never
  processed, so no supervisor working through the isolate can recover it.
  With `unresponsiveTimeout` set, the main side pings the isolate's message
  loop (`PingMessage`, answered immediately); ~3 consecutive missed probes
  abandon the wedged isolate (best-effort kill — a thread blocked in native
  code leaks until the call returns, which beats a frozen client) and respawn
  a fresh one behind the same `ClientIsolate` object:
  - pending requests complete with the new `ClientIsolateRespawnedException`
    (callers retry);
  - monitored-item streams get that error and close, so callers resubscribe;
  - `stateStream` / `reconnectStream` objects survive and keep emitting from
    the new isolate;
  - the in-isolate `keepConnected` supervisor is re-armed, so the session
    reconnects without caller action.
  Opt-in: `unresponsiveTimeout` defaults to null (no behavior change).
  Respawn cycles back off exponentially (up to 1 minute) so a genuinely dead
  endpoint is retried gently — every respawn abandons a native client, and a
  tight loop would itself leak resources.
  `debugWedgeIsolate` (test-only) simulates the wedge deterministically.
- Export `ClientIsolateClosedException` and `ClientIsolateRespawnedException`.

## 1.5.7+1

- `ClientIsolate.keepConnected` / `stopKeepConnected` / `reconnectStream`:
  the auto-reconnect supervisor introduced for `Client` in 1.5.7 is now
  available on the isolate client too, by delegating to the native client's
  supervisor inside the isolate. This matters because the isolate client is
  where a dead session is the most invisible: the caller-side `runIterate()`
  future only completes when native run_iterate returns non-GOOD, so a
  session that dies while iterate keeps reporting GOOD (seen in production:
  channel expiring mid-session-create, server FIN never surfacing) parks the
  caller forever with no error. With `keepConnected` the supervisor and its
  pump live inside the isolate, so recovery does not depend on any error
  ever reaching the caller. Starting it stops any caller-driven
  `runIterate()` loop — the supervisor owns the pump, same contract as
  `Client.keepConnected`.

## 1.5.7

- Bump bundled open62541 from `v1.5.6` to `v1.5.7`.
  - Upstream v1.5.7 is a maintenance release focused on security hardening and
    stability: rejects custom DataType definitions that overflow
    `memSize`/`membersSize`, fixes a PubSub off-by-one heap-OOB read in
    `getFieldMetaData`, guards several server-side use-after-free / NULL-deref /
    recursion-depth issues, and tightens URI and certificate-subject handling in
    plugins. See https://github.com/open62541/open62541/releases/tag/v1.5.7.
  - Regenerated the amalgamated header
    (`third_party/open62541/open62541_modified.h`), the `remove_bitfields.patch`
    line offsets, and the ffigen bindings (`lib/src/third_party/open62541.g.dart`)
    against v1.5.7. Struct layouts are unchanged: `UA_ClientConfig` (888 bytes)
    and `UA_DataType` (96 bytes) match the previous release, so
    `verify_sizes_test` still passes.
- Hardened the native build hook (`hook/build.dart`): every third-party source
  archive is now fetched over HTTPS (scheme enforced in code) and verified
  against a pinned SHA-256 before use, failing the build loudly on mismatch.
- Prepared the package for pub.dev publishing: expanded the description, added
  `homepage`/`issue_tracker` metadata, raised the SDK floor to `^3.10.0` (native
  build hooks are stable from Dart 3.10), and added an `example/`.

Native-build feature set (built from source at install time via Dart native
build hooks, downloading open62541 and mbedTLS `3.6.5` and building them with
CMake):

- Enable OPC UA encryption through mbedTLS (`SignAndEncrypt`).
- Force little-endian IEEE 754 float encoding so subnormal `Float`/`Double`
  values round-trip correctly on all supported targets.
- Patch the client subscription handler so `deleteCallback` fires for every
  client-side subscription when the server reports `BadNoSubscription`
  (OPC UA Part 4, 5.13.5).
- Client APIs: connect/reconnect, browse and recursive tree browse,
  subscriptions and monitored items, secure connections with certificates.
- Server APIs: variable nodes, array and structure (custom type) nodes,
  data-type nodes, and variable monitoring streams.
- Supports Linux, macOS, Windows, Android and iOS.
