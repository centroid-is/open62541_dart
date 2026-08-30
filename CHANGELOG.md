# Changelog

The version number tracks the bundled [open62541](https://github.com/open62541/open62541)
release, followed by a package revision suffix (`+1`, `+2`, ...) for Dart-side
changes that ship the same native library version.

## 1.5.7+3

- **Data-source reads carry a status code + source timestamp.**
  `Server.addDataSourceVariableNode` gained `onReadValue`, a richer alternative
  to `onRead` (provide exactly one): it returns a `DataSourceValue`
  (`value` + `statusCode` + optional `sourceTimestamp`), letting a proxy serve
  e.g. its last-known value with `Bad_NoCommunication` while the backing
  device is down instead of silently reporting stale data as Good (a Bad
  status still carries the value, as OPC UA allows). On the client,
  `Client.readValue(nodeId)` (also on `ClientApi`/`ClientIsolate`) returns a
  `DataValue` — decoded value, operation `statusCode`
  (`isGood`/`isUncertain`/`isBad`), `sourceTimestamp` and `serverTimestamp` —
  and does NOT throw on a non-Good operation status; `Client.read`/
  `readAttribute` keep their existing throw-on-non-Good behavior. Monitored
  items already surfaced a non-Good notification as a stream *error* event
  (the notification's value/timestamps are not delivered on the data stream);
  that behavior is unchanged and now documented — the error carries the
  decoded status. Also exported: `statusCodeToString` and the
  `UA_STATUSCODE_BADNOCOMMUNICATION` / `BADNOTWRITABLE` / `BADUSERACCESSDENIED`
  / `BADINTERNALERROR` constants.
## 1.5.7+2

- Bounded-send fix (native build hook): patch open62541's TCP send path so a
  dead/half-open connection can no longer wedge the client forever. In
  `TCP_sendWithConnection` (`arch/posix/eventloop_posix_tcp.c`), when the OS
  send buffer fills against a peer that keeps the socket open but stops draining,
  `UA_send` returns `EWOULDBLOCK` and open62541 spins a `poll(POLLOUT, 100ms)`
  retry loop with no overall deadline; `POLLOUT` never arrives (and on Windows
  WSAPoll never reports `POLLHUP`/`POLLERR` for a peer gone without RST), so the
  call — made synchronously from `UA_Client_run_iterate` on the client isolate's
  single event-loop thread — never returns and freezes the whole isolate. The
  fix adds a monotonic wall-clock deadline (compile-time constant
  `UA62541_DART_SEND_DEADLINE_MS`, default 5000 ms): on timeout the send is
  treated as a dead connection and shuts down exactly like any other send error,
  so `run_iterate` returns, `connectStatus` goes bad, and the existing
  `keepConnected` supervisor reconnects — no isolate killed, no `UA_Client`
  leaked. The deadline is wall-clock and independent of what poll reports, so it
  fixes every platform including the Windows WSAPoll case. The change ships as a
  unified-diff patch file (`hook/bounded_send_deadline.patch`) that the build
  hook applies to the extracted open62541 source with a standard patch tool
  (`git apply -p1`, falling back to `patch -p1`); a missing patch file, a
  missing target file, or a non-zero exit from the patch tool fails the build
  loudly. Bundled open62541 is unchanged (still v1.5.7); this is a binding-only
  build change.

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
