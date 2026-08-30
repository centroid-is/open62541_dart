# Changelog

The version number tracks the bundled [open62541](https://github.com/open62541/open62541)
release, followed by a package revision suffix (`+1`, `+2`, ...) for Dart-side
changes that ship the same native library version.

## Unreleased

- **BREAKING: method callbacks receive the calling session's identity.**
  `Server.addMethodNode`'s `callback` signature changed from
  `(List<DynamicValue> inputs)` to
  `(List<DynamicValue> inputs, MethodSessionInfo session)`. The new
  `MethodSessionInfo` carries the calling session's `sessionId` (the Guid
  NodeId open62541 assigns), `sessionName`, the client's `applicationUri` /
  `applicationName` (from the session's `0:clientDescription` attribute) and
  the activation `identity` — a sealed `SessionIdentity` that is
  `AnonymousSessionIdentity`, `UsernameSessionIdentity` (the
  UserNameIdentityToken's userName) or `CertificateSessionIdentity` (the X509
  token's subject DN), resolved from open62541's session attributes and the
  NS0 SessionSecurityDiagnosticsArray. Update existing handlers by adding the
  second parameter: `callback: (inputs, session) { ... }`.
- **`Server.setVariableValueSource` — take over existing (incl. NS0) variable
  nodes.** Replaces the value source of an existing variable node with live
  Dart callbacks (`onRead`/`onReadValue` + optional `onWrite`), the same
  mechanism as `addDataSourceVariableNode` but without creating a node. This
  unlocks the NS0 redundancy surface open62541 1.5 otherwise pins:
  `Server/ServiceLevel` (`ns=0;i=2267`, internally fixed at 255) and
  `Server/ServerRedundancy/RedundancySupport` (`ns=0;i=3709`, stored `None`)
  now serve whatever the callback returns. The standard `ServerUriArray`
  property (`ns=0;i=11314`, deleted from NS0 by open62541 at startup) can be
  re-added with `addVariableNode` under ServerRedundancy (`i=2296`,
  HasProperty/PropertyType) — see `test/ns0_value_source_test.dart`.
- `ClientConfig` gained `applicationUri`, `applicationName` and `sessionName`
  getters/setters (set before connecting) so a client can declare the
  ApplicationDescription and session name the server observes.
- Fixed `ClientConfig` wrapping a stale config struct: `UA_Client_newWithConfig`
  *copies* the config into the client, so post-construction writes through the
  previously wrapped temporary (e.g. the `securityMode` / `securityPolicyUri`
  setters) never reached the running client — and freed strings the client's
  copy still pointed at. `ClientConfig` now wraps the client's live config
  (`UA_Client_getConfig`), and the temporary struct is freed instead of leaked.

## 1.5.7+3

- **Dependency prune:** dropped `tuple` (the `Tuple2<NodeId, AttributeId>`
  keys in the client's monitored-items bookkeeping are now Dart 3 records,
  same structural equality) and the unused `collection` dependency.
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
- **Typed status-code rejection for data-source writes.** New
  `UaStatusException(statusCode)` (exported): a data-source `onWrite` that
  throws it answers the client with exactly that status code — e.g.
  `Bad_NotWritable` (0x803B0000) for a gate-denied write or
  `Bad_UserAccessDenied` (0x801F0000) — instead of the generic
  `Bad_InternalError` that any other throw still maps to. The read dispatcher
  honors it symmetrically (`onRead`/`onReadValue` throwing one fails the read
  with that code and no value). Client side, the code is now extractable:
  `Client.write` fails with a `UaStatusException` carrying the operation (or
  service) status instead of a formatted string, and a monitored-item stream's
  error event for a non-Good notification is a `UaStatusException` too (was a
  string; `ClientIsolate` still marshals stream/request errors as strings
  across the isolate boundary, so there the code survives only inside the
  message text).
- **Server session/subscription statistics.** New `Server.statistics` returns
  a `ServerStatistics` snapshot: the secure-channel counters
  (`currentChannelCount`, `cumulatedChannelCount`, rejected/timeout/abort/
  purge) and session counters (`currentSessionCount`,
  `cumulatedSessionCount`, securityRejected/rejected/timeout/abort) from
  `UA_Server_getStatistics()`, plus `currentSubscriptionCount`,
  `cumulatedSubscriptionCount` and `currentMonitoredItemCount` (the sum of
  the per-subscription `monitoredItemCount`s) read from the NS0
  server-diagnostics nodes. No native/CMake change was needed:
  `UA_ENABLE_DIAGNOSTICS` is ON by default in open62541 1.5.7 and was already
  part of this package's build — the subscription-side fields are typed
  nullable and come back `null` only on a build without those NS0 nodes.
  Regenerated the FFI bindings (additive) with `UA_Server_getStatistics` and
  the `UA_ServerStatistics` / `UA_SecureChannelStatistics` /
  `UA_SessionStatistics` / `UA_ServerDiagnosticsSummaryDataType` /
  `UA_SubscriptionDiagnosticsDataType` structs; `test/verify_sizes_test.dart`
  pins their layouts against the native type table.
- **PubSub (OPC UA Part 14) support**, UDP + UADP transport. The native build
  now enables `UA_ENABLE_PUBSUB` and `UA_ENABLE_PUBSUB_INFORMATIONMODEL`
  (bundled open62541 still v1.5.7; MQTT/SKS/raw-Ethernet transports stay off),
  and `Server` gained an idiomatic PubSub API. Publisher side:
  `addPubSubConnection` (UDP multicast/unicast URL + `PubSubPublisherId`),
  `addPublishedDataSet`, `addDataSetField` (publishes an existing variable
  node), `addWriterGroup` (publishing interval; UADP message settings default
  to sending PublisherId/GroupHeader/WriterGroupId/PayloadHeader so readers can
  match) and `addDataSetWriter`. Subscriber side (which in OPC UA also hangs
  off the *server*): `addReaderGroup`, `addDataSetReader` (matches
  publisherId/writerGroupId/dataSetWriterId and carries the DataSetMetaData
  built from `DataSetFieldMeta` entries) and `setDataSetReaderTargetVariables`
  (maps received fields positionally into local variable nodes). Components
  are created disabled; `enableAllPubSubComponents` /
  `disableAllPubSubComponents` drive the Part 14 state machine and the
  per-component states are readable via `writerGroupState` /
  `dataSetWriterState` / `readerGroupState` / `dataSetReaderState`
  (`PubSubState`). `triggerWriterGroupPublish` publishes on demand.
- `Server.onValueChanged(nodeId)`: a broadcast stream of every value written to
  a variable node (client writes, `Server.write`, and PubSub DataSetReader
  deliveries into target variables), backed by open62541's after-write value
  notification — the idiomatic way to consume received PubSub values.
- `NodeId` now supports GUID identifiers (`NodeId.fromGuid`, `isGuid()`,
  `guid`, `ns=X;g=...` formatting). Needed because open62541 identifies
  DataSetFields by GUID NodeIds; previously `NodeId.fromRaw` threw on any
  GUID-typed id.
- Regenerated the FFI bindings with the PubSub API surface
  (`UA_Server_addPubSubConnection`, `UA_Server_addPublishedDataSet`,
  `UA_Server_addDataSetField`, `UA_Server_addWriterGroup`,
  `UA_Server_addDataSetWriter`, `UA_Server_addReaderGroup`,
  `UA_Server_addDataSetReader`, `UA_Server_setDataSetReaderTargetVariables`,
  enable/disable/state functions, and the PubSub config structs).
  `test/verify_sizes_test.dart` pins the grown `UA_ServerConfig` (now embeds
  `UA_PubSubConfiguration`) and the PubSub config struct layouts;
  `UA_ClientConfig` is unchanged.
- Not yet exposed: delta frames (`keyFrameCount` is plumbed but open62541's
  `enableDeltaFrames` server option is left off), metadata
  ConfigurationVersion handling, PubSub message security (SKS/security
  policies), MQTT/Ethernet transports, and standalone SubscribedDataSets.

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
