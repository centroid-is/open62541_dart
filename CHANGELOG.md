# Changelog

The version number tracks the bundled [open62541](https://github.com/open62541/open62541)
release, followed by a package revision suffix (`+1`, `+2`, ...) for Dart-side
changes that ship the same native library version.

## 1.5.9

- **Monitoring with quality: `monitorDataValue` / `monitoredDataValues`.**
  `Client` and `ClientIsolate` implement the new `DataValueMonitoringApi`,
  two methods mirroring `monitor` / `monitoredItems` that emit every sample
  as a `DataValue` (the type `readValue` returns): the value, the server's
  status code and the source/server timestamps of the notification. A sample
  with a non-Good status is delivered with its code (`DataValue.isGood` /
  `isUncertain` / `isBad`) and the value it carries, or else the last known
  one; a Good sample without a value is a null value; a timestamp the
  notification does not carry (or carries as the null timestamp, tick 0) is
  null, never the previous sample's. A Bad sample of a monitored attribute
  other than Value has no field to travel in and is a `UaStatusException`
  error on the stream. Every event is a fresh map of fresh `DataValue`
  objects over copies of the values, on both client types. The existing
  `monitor` / `monitoredItems` are unchanged (value only; a non-Good status
  is a `UaStatusException` error and nothing is delivered for that sample),
  and so are `ClientApi` and `DynamicValue`: the new methods live on their
  own interface because Dart requires an `implements` class to define every
  member of its interface, so a class written against `ClientApi` keeps
  compiling. Code holding a `ClientApi` checks `is DataValueMonitoringApi`.
- **Fixed: a Good answer carrying an empty variant killed the process.** A
  server may answer an attribute read, a data-change notification or a method
  output with status Good and an empty variant ("the attribute exists and has
  no value" — python-asyncua does this for the `DataTypeDefinition` of its
  base DataType nodes). `Client.readAttribute`, the monitored-item callback
  and the decode behind `Client.call` dereferenced the empty variant's NULL
  type/data pointers natively: a SIGSEGV, not a catchable Dart error. An
  empty **Value** now reads as a null `DynamicValue`: `readAttribute` returns
  the node with a null value, `read` and `call` return a null `DynamicValue`,
  and a monitored item emits null — also when a node that had a value goes
  empty (the previous value is not re-emitted). Any other attribute
  (`Description`, `DisplayName`, `DataType`, `DataTypeDefinition`) answered
  Good and empty is treated as absent, like the already tolerated
  `BadAttributeIdInvalid`.
- **`ua_malloc` is gone; the package allocates with `ua_calloc` only
  (#45).** Every buffer handed to open62541 or freed with `free()` came from
  one of two allocators that differed only in zero-filling; the malloc one is
  removed (`UaMallocAllocator`, `ua_malloc`, never exported), `NodeId.toRaw`
  defaults to `ua_calloc`, and the heap-growth tests measure through it.

- **BREAKING: `DynamicValue.asInt`, `asDouble` and `asBool` are nullable
  (#115).** They returned `0`, `0.0` and `false` for a value that is missing
  or of another type, which in process data is a plausible reading rather
  than a failure, so a node that was not read or a member that did not
  decode looked like a zero downstream. They are `int?`, `double?` and
  `bool?` now and return null there, like `asDateTime` always did; the
  coercions stay (a num reads as int or double, a numeric string parses, a
  non-zero num is true, `'true'`/`'1'` and `'false'`/`'0'` are bools). A
  caller that did arithmetic on the result or passed it where a non-null
  number is expected has to check for null (or `!` where the value is known
  present). Also: a `DateTime` value reported `DynamicType.unknown`; `type`
  now reports `DynamicType.datetime`, `isDateTime` goes with it, and
  `DynamicType` is exported.

- **A refused monitored item fails the stream with `MonitoredItemsRefused`,
  not a `String` (#38).** When the server refuses an item of a
  `monitoredItems` create (`BadNodeIdUnknown` for a node it does not have,
  ...), the stream's error was the formatted message, so a caller could match
  neither the type nor the status; the service-level failure of the same
  create was already a `UaStatusException`. The error is now a
  `MonitoredItemsRefused`, a `UaStatusException` with the first refused item's
  status as `statusCode` and every refused item's status in `failures`
  (`(NodeId, AttributeId)` to status). `toString()` is the old message, and
  `ClientIsolate` forwards it typed.

- **The well-known NS0 nodes are `NodeId` statics (#110).** Reading the
  server's status, service level, namespace array or redundancy surface, or
  adding a standard property, needed the generated `UA_NS0ID_*` constants,
  an implementation import. `NodeId.server`, `serverArray`,
  `namespaceArray`, `serverStatus`, `serverStatusStartTime`,
  `serverStatusState`, `serverStatusBuildInfo`, `serviceLevel`,
  `serverRedundancy`, `redundancySupport`, `serverUriArray`, `organizes`,
  `hasComponent`, `hasProperty`, `hasTypeDefinition`, `baseObjectType`,
  `folderType`, `baseDataVariableType` and `propertyType` join the existing
  folder and reference-type statics, each backed by the generated constant
  (`serverStatusCurrentTime` was a literal `2258`).
- **`Client.keepConnected(nonBlocking: true)`: a pump that does not block the
  owning isolate.** By default the supervisor's pump calls
  `runIterate(iterateInterval)`, which sits in open62541's `select()` for up
  to `iterateInterval`, so a `Client` has needed an isolate of its own (or a
  `ClientIsolate`). With `nonBlocking: true` the pump calls
  `runIterate(Duration.zero)`, a zero-timeout poll that still fires due timers
  and drains ready sockets, and then yields for `iterateInterval` like any
  other timer; `iterateInterval` becomes the poll cadence (and the floor on
  notification latency; 1 ms is reasonable for a fan-in). The client can then
  share the isolate that consumes its data: several clients on one isolate,
  or a client on a UI isolate. The default is `false`, so existing callers
  keep their exact behaviour. `runIterate` is documented as a timeout, with
  `Duration.zero` as the non-blocking poll. `tool/bench_pump.dart` measures
  the cost.
- **`Server.port`: the port the server listens on, for `Server(port: 0)`.**
  open62541 supports dynamic port assignment (the listen socket binds port 0
  and `getsockname` reads what the OS picked), but on a dual-stack host its
  IPv4 and IPv6 listen sockets each got their own OS-picked port and the
  server advertised both. The bundled source is patched
  (`hook/dynamic_port.patch`) to bind the IPv4 addresses first and reuse the
  port the OS picked for them for the other address families, so a server has
  ONE port; `Server.port` reads it back once `start()` has returned
  (`StateError` before). The test suite starts every server on port 0 now
  instead of probing for a free port and handing it over, which raced across
  the suites `dart test` runs in parallel (two servers given one port both
  bound it, since open62541's listen sockets are `SO_REUSEPORT`).
- **Fixed: VM abort (`Callback invoked after it has been deleted`) after a
  lost DeleteMonitoredItems response.** Cancelling a monitored-item stream
  closed the stream's native callback as soon as the delete request was
  answered, whatever the answer. When the response is lost with the secure
  channel (a frozen or dropped link while the cancel is in flight), the
  request is answered locally with `BadSecureChannelClosed`; the item still
  exists in the native client and, because the session outlives the channel,
  on the server. After the reconnect it published into the closed callback
  and aborted the process. The callback is now closed on a delete response
  only when the items are really gone (Good service result, every item Good
  or `BadMonitoredItemIdInvalid`); otherwise it stays open and is released
  by `Client.delete()`, as for a delete that could not be sent.
- **Fixed: `ClientIsolate.delete()` failed with `Concurrent modification
  during iteration` when a stream ended during the teardown.** The worker
  cancelled its streams while iterating the map a finishing stream removes
  itself from (for example a refused monitored-item create answered at that
  moment). The delete then failed before the worker deleted its client, so
  the server kept the session and its subscriptions.
- **Requests on a dead connection fail instead of hanging.** When the secure
  channel is down, open62541 refuses a request before sending it and never
  calls back. `Client.write()` and `Client.subscriptionCreate()` ignored that
  status, so the future they returned never completed; both now throw
  `UaStatusException(BadServerNotConnected)`, and
  `UA_STATUSCODE_BADSERVERNOTCONNECTED` is exported to match on. Cancelling a
  monitored-item stream hung the same way on the refused
  DeleteMonitoredItems request; `cancel()` on a dead connection now
  completes.
- **Fixed: native callbacks leaked by refused requests.** Each of these left
  a native callback open for the lifetime of the isolate, together with what
  its closure captured, and an isolate with an open native callback cannot
  exit:
  - a monitored-item create the server refuses (`BadNodeIdUnknown`, ...)
    never closed the item's data callback, which holds the item's last
    value. A caller that rebuilds a refused item leaked one per attempt;
  - `Client.write()` closed its callback only when the write succeeded, so
    a write the server rejected (`BadNotWritable`, ...) leaked it;
  - a `write()` or `subscriptionCreate()` refused on a dead connection
    leaked the callbacks it had registered, and the write its variant.
- **Fixed: a monitored item torn down on a dead connection kept its native
  callback open for good.** With the secure channel down, DeleteMonitoredItems
  cannot be sent. The item's native callback has to stay open at that point:
  the item survives on the server with its session, and publishes into the
  callback again once the client has reconnected. It is now closed when
  `Client.delete()` has freed the native client, so an isolate that cancelled
  an item (or deleted its client with the stream still active) on a dead
  connection can exit. Known limitation: the delete is not retried when the
  session comes back, so the server keeps sampling the cancelled item until
  the session or the subscription ends.
- **Fixed: tearing down a `monitoredItems` stream that has no monitored
  item.** When the server refuses every item of a create with a tolerated
  status (`BadAttributeIdInvalid`, e.g. the Value attribute of an Object
  node), the stream stays open with nothing behind it. Cancelling it, or
  deleting the client while it was active, treated the already answered
  create as still in flight: it read the freed request id, sent a Cancel for
  whatever that slot held and never closed the stream's native callback, so
  an isolate that did this could not exit. The teardown now releases the
  callback and completes.
- **Fixed: `ClientIsolate.delete()` left the worker isolate running when the
  worker answered the delete with an error.** The error was rethrown before
  the worker was killed and the two receive ports were closed, so the worker
  stayed alive and the open ports kept the calling isolate (and with it a CLI
  process) from exiting. `delete()` now always kills the worker and closes
  its ports; the error is still reported to the caller.
- **Fixed a 48-byte native leak per struct-valued variant decoded (and per
  struct written).** `OpcUaDynamicValueSerializer.deserialize` calloc'd a
  `UA_ExtensionObject` to read the header of every struct-valued variant --
  every struct notification, every struct read, and once per element of an
  array of structs -- and never freed it; `serialize` did the same for every
  struct written. Both now read/build the header through a `Struct.create`
  view on the Dart heap, so the garbage collector owns it. Present in 1.5.7
  through 1.5.7+3.
- **A struct write that fails no longer leaks.** When serialising a struct
  threw part-way (a field without a value, for example), the type id string
  already allocated for it was never freed, nor were the bodies and type ids
  of the elements before it in an array of structs. The whole value is now
  encoded on the Dart heap first, and the native memory the variant takes
  ownership of is allocated only once nothing can throw any more.
- Bump bundled open62541 from `v1.5.7` to `v1.5.9` (v1.5.8 was never shipped
  by this package; both upstream releases land here).
  - Upstream v1.5.8 is a maintenance release focused on hardening and
    stability: overflow/bounds checks across the binary, JSON and XML
    decoders and the SecureChannel chunk/OPN handling; server MonitoredItem
    fixes (items follow a node on replacement, reentrant/local deletion from
    callbacks, O(1) removal and a lookup tree instead of quadratic scans);
    the client validates the service result before reading result arrays and
    no longer runs the connectivity check before the Session is activated;
    and a batch of PubSub transport/encoding fixes (UADP security headers,
    oversized DataSetMessages, RawData metadata, MQTT/Ethernet). See
    https://github.com/open62541/open62541/releases/tag/v1.5.8.
  - Upstream v1.5.9 continues the hardening: SecureChannel TokenId and OPN
    renewal SequenceNumber checks; the server validates HEL messages
    (trailing data, EndpointUrl length), endpoint security modes, event
    filter operators, attribute ids, GetMonitoredItems / ConditionRefresh /
    GDS method arguments and session user identity changes, bounds
    diagnostics member names, and sends a PublishResponse when cancelling a
    queued Publish; the client deep-copies owned `UA_ClientConfig` members
    (`UA_ClientConfig_copy`), frees the OpenSecureChannelResponse on every
    exit path, initialises async responses before decoding and keeps
    previous SecurityPolicy arrays alive while open channels reference them;
    plugins validate RSA-PSS / ECDSA signature lengths and use constant-time
    MAC comparison; plus a large batch of PubSub/SKS fixes and thread-safety
    fixes in `arch` (no `gmtime` / `inet_ntoa`). See
    https://github.com/open62541/open62541/releases/tag/v1.5.9.
  - Regenerated the amalgamated header
    (`third_party/open62541/open62541_modified.h`) and the ffigen bindings
    (`lib/src/third_party/open62541.g.dart`) against v1.5.9.
    `remove_bitfields.patch` applies unchanged. One struct-layout change:
    `UA_ClientConfig` gained the internal `securityPolicyHistory` pointer
    after `authSecurityPolicies` (888 -> 896 bytes on 64-bit;
    `verify_sizes_test` updated). The Dart wrappers access the config only
    through the generated struct fields and `UA_Client_newWithConfig` still
    takes the struct by value, so nothing in `lib/` changes. The new
    `UA_ClientConfig_PolicyHistory` type is bound as opaque (internal
    ownership). The only other public-header addition across both releases
    is `UA_Node_moveMonitoredItems` (custom-nodestore API, not bound).
  - All build-time source patches (subscription cleanup, bounded send,
    session-recreate race, delete-by-client-handle, single-threaded
    AsyncManager) still apply to v1.5.9; none has landed upstream yet
    (`ua_client_subscriptions.c` and `eventloop_posix_tcp.c` are unchanged
    between v1.5.8 and v1.5.9, and the v1.5.9 edits to `ua_client.c`,
    `ua_client_connect.c` and `ua_server.c` do not touch the patched code).
- **Build: the hook re-downloads open62541 when the pinned version changes.**
  The extracted source tree in the shared hook output directory was reused
  whenever it existed, whatever version it held, so a project upgraded with
  a warm `.dart_tool` kept building the previous open62541 release under the
  new bindings. The tree is now stamped with its version and discarded on a
  mismatch (an unstamped tree from an older package revision is discarded
  once). `verify_version_test` additionally checks the version the native
  library reports, not only the constant in the generated bindings.
- **Build: the hook re-downloads and rebuilds mbedTLS when the pinned version
  changes.** The same flaw as above for the bundled mbedTLS: the extracted
  source and the per-target install prefixes under `tls/` were reused whenever
  they existed, so a warm `.dart_tool` would have kept linking the previous
  mbedTLS release across a version bump. The tree is now stamped with its
  version and discarded, together with every install built from it, on a
  mismatch or a missing stamp. One-time cost: a checkout or consumer whose
  cache predates the stamp re-downloads and rebuilds mbedTLS once on the next
  build (well under a minute on a fast workstation, a couple of minutes on CI
  or a laptop); later builds reuse the stamped tree as before.
- **Dev tooling: `ffigen` 22 / 23.** The binding generator (`tool/ffigen.dart`)
  is ported to ffigen 22's visitor-based config API, which replaced the one it
  was written against; ffigen 23 keeps that API. The generated bindings are
  unchanged by the port and identical under 22.0.0, 22.1.0 and 23.0.0.
  ffigen 22 depends on `code_assets` 2.x, so development now resolves
  `code_assets` 2.x. Nothing changes for consumers: `ffigen` is a dev
  dependency and the runtime constraint (`code_assets: >=1.0.0 <3.0.0`) is
  the same.
- **`Client.call` (and `readAttribute` / monitored-item creation) surface the
  real service status.** The async response handlers checked `resultsSize`
  before `responseHeader.serviceResult`, so an infrastructure failure (session
  torn down, secure channel closed, timeout) — which legitimately answers with
  zero results — was reported as a misleading `"No results"` error. The
  service-level status is now checked first and failures complete with a typed
  `UaStatusException` carrying the exact status code. The `"No results"` /
  `"multiple results"` errors remain for genuinely Good-but-malformed
  responses.
- **BREAKING: data-source `onWrite` callbacks are async.**
  `Server.addDataSourceVariableNode` / `Server.setVariableValueSource` take
  `Future<void> Function(DynamicValue)` for `onWrite`. The client's write
  parks as an open62541 async operation and is answered with the handler's
  awaited outcome — complete normally for `Good`, complete with a
  `UaStatusException` for that exact code, anything else for
  `Bad_InternalError` — so a proxy can answer with the REAL downstream
  (device) result instead of an optimistic Good. Writes not completed within
  `Server.asyncOperationTimeout` are cancelled with `Bad_Timeout`. Migrate
  handlers by adding `async`.
- **BREAKING: method callbacks are async.** `Server.addMethodNode`'s
  `callback` now returns `Future<List<DynamicValue>>`. The call is parked as
  an open62541 async operation (`GoodCompletesAsynchronously`) and the
  client's request stays in flight — without blocking the server's iterate
  loop — until the future completes; the response goes out on a following
  `runIterate`. Multiple calls can be in flight concurrently. A
  `UaStatusException` completes the call with exactly that status; any other
  error yields `Bad_InternalError`. Calls not completed within
  `Server.asyncOperationTimeout` (new getter/setter, default 2 minutes) are
  cancelled with `Bad_Timeout`, and unfinished calls are dropped on shutdown.
  The sync path is removed (async is the API): migrate handlers by adding
  `async` — `callback: (inputs, session) async { ... }`.
- **Fixed: only the first method output argument reached the caller.**
  `Client.call`'s response callback is async, and open62541 frees the
  `UA_CallResponse` the moment the native callback returns (at the first
  `await`) — outputs beyond index 0 were read from freed memory. The client
  now deep-copies every output variant synchronously before decoding, so
  multi-output methods return all outputs, typed.
- **Build: the server's AsyncManager now also runs in single-threaded
  builds** (`hook/build.dart` source patch). open62541 1.5.7 compiles the
  async-operation service paths unconditionally but only initializes the
  AsyncManager under `UA_MULTITHREADING >= 100`, so the first parked async
  operation in this package's `UA_MULTITHREADING=0` build crashed on an
  uninitialized queue. The threading model is unchanged.
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
- Fixed a process-lifetime leak in `ClientIsolate`: the worker's error
  `ReceivePort` was never closed, so a process (e.g. a CLI) that created a
  `ClientIsolate` never exited after `delete()` — the open port kept the main
  isolate alive indefinitely. `delete()` now closes it.
- Fixed `ClientConfig` wrapping a stale config struct: `UA_Client_newWithConfig`
  *copies* the config into the client, so post-construction writes through the
  previously wrapped temporary (e.g. the `securityMode` / `securityPolicyUri`
  setters) never reached the running client — and freed strings the client's
  copy still pointed at. `ClientConfig` now wraps the client's live config
  (`UA_Client_getConfig`), and the temporary struct is freed instead of leaked.
- **`Server.write` surfaces the native status code**: it now throws a
  `UaStatusException` when the write is not Good (e.g. `Bad_NodeIdUnknown`,
  `Bad_TypeMismatch`). Previously the status was silently discarded and
  callers had to verify by reading back. Callers that deliberately probed
  with best-effort writes should wrap the call in try/catch.
- **A bare `ClientIsolate.connect()` no longer deadlocks**: the worker
  isolate pumps its own iterate loop for the duration of the handshake, so
  `connect()` completes without `keepConnected`/`runIterate` running. It
  also gained a `timeout` parameter (default 30 s): an unreachable endpoint
  now fails with `UaStatusException(Bad_Timeout)` instead of waiting
  forever. After activation the pump stops — session traffic still needs
  `keepConnected` (preferred) or a `runIterate` loop.
- **`UaStatusException` survives the `ClientIsolate` boundary**: worker-side
  errors of that type now cross to the caller as typed exceptions with their
  status code intact (`on UaStatusException catch (e) => e.statusCode`);
  every other error type still arrives as the stringified fallback.
- **Fixed: `Server.addVariableTypeNode` killed the process.** It freed the
  value's variant and then the attributes holding a shallow copy of it, so
  the payload was freed twice on every call (glibc:
  `free(): double free detected in tcache 2`).
- **Fixed: `Client.browse` killed the process when the server paged its
  answer.** A server may return the references of a node a few at a time,
  with a continuation point to fetch the rest. Following it (BrowseNext)
  freed the continuation point by hand and then again with the request that
  owned it (glibc: `free(): invalid pointer`). Nothing in this package made
  a server page, so the new `Server.maxReferencesPerNode` (getter/setter,
  default 0: no limit) sets how many references it returns per response.
- **Fixed: native memory that was allocated and never freed.** Each of these
  stayed on the C heap for the lifetime of the process:
  - every `Server` left its 1.2 kB `UA_ServerConfig` struct behind.
    `UA_Server_newWithConfig` moves the contents into the server but leaves
    the struct itself to the caller.
  - every node added to a `Server` left a copy of its browse name behind
    (`addVariableNode`, `addDataSourceVariableNode`, `addVariableTypeNode`,
    `addMethodNode`, `addObjectNode`, `addFolderNode`, `addDataTypeNode`).
  - an add that threw left more: `addVariableNode` for a value without a
    name leaked the attributes and the value (about 300 bytes),
    `addMethodNode` the attributes and the arguments marshalled so far when
    an argument could not be marshalled, and `addObjectNode`,
    `addFolderNode` and `addDataTypeNode` the attributes whenever the server
    refused the node (`BadNodeIdExists`, ...).
  - a `Client` created with a `username` left a copy of the username and of
    the password behind.
  - every `Client.connect()` left a copy of the endpoint URL behind, as did
    every reconnect attempt of `keepConnected()`.
  - every `Client.write()` to a node with a string NodeId left a copy of the
    identifier behind.
  - every `Client.call()` left its argument array behind, and a copy of the
    identifier of each string NodeId. A call that failed before it was sent
    (an argument that cannot be encoded, a client that is not connected) also
    left the arguments encoded so far.

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
