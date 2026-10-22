# Changelog

The version number tracks the bundled [open62541](https://github.com/open62541/open62541)
release, followed by a package revision suffix (`+1`, `+2`, ...) for Dart-side
changes that ship the same native library version.

## 1.5.9

- **CI's ASan/UBSan lane now sanitises.** The hooks runner starts build hooks
  with a scrubbed environment, so `OPEN62541_DART_SANITIZER` (and
  `ENABLE_SANITIZER` before it) never reached the hook and `test-asan` ran
  against a plain library. The switch is now an empty `.open62541_sanitizer`
  file in the package root (gitignored; the hook reruns when it appears or
  goes). The job asserts `__asan_` symbols in the built library, and
  `test/native_sanitizer_test.dart` checks the loaded one.
- **Fixed (security): a server could make the client read out-of-bounds native
  memory by sending a value whose type disagreed with the type it declared.**
  `Client.read` passed the node's DataType attribute to the variant decoder as
  a hint and chose the native payload reader from it, rather than from the type
  open62541 actually decoded from the wire. A server that advertised one
  built-in type but put another on the wire (a DataType attribute that
  disagrees with the value on the wire) could therefore have the raw bytes read
  under the wrong layout — an out-of-bounds read that could crash the client or
  leak memory. The decoder now keys the reader on the wire type and raises a
  typed `UaTypeMismatch` (an `on UaStatusException`, carrying `Bad_TypeMismatch`
  and the expected/actual NodeIds; it crosses the `ClientIsolate` boundary as
  itself) when the declared and wire types are different built-ins; the client
  stays usable. `readValue` and the monitored-item callbacks were never
  affected (they pass no hint).
- **The compile and link hardening reaches the native build again.** The hook
  passed `-fstack-protector-strong -D_FORTIFY_SOURCE=2` and
  `UA_FLOAT_LITTLE_ENDIAN=1` as `CMAKE_C_FLAGS`, which the toolchain files of
  `native_toolchain_cmake` overwrite (`-march=...`), so a fresh build dropped
  them. They now go in a script given as `CMAKE_PROJECT_INCLUDE`, which runs
  after the toolchain.
- **A custom structure is laid out the way C lays it out.**
  `Server.addCustomType` packed the members of the `UA_DataType` it
  registers with open62541 with no padding, so a member after a narrower one
  sat at an unaligned offset (`ST_Test { Int32 Id; Double Value; Boolean
  Enabled; String Label }` put `Value` at 4 and `Label` at 13). open62541
  read and wrote those members misaligned: UBSan reported it on x86-64, and a
  strict-alignment CPU (32-bit ARM, Android armv7) can fault. Each member now
  starts at a multiple of its C alignment and the size is rounded up to the
  struct's, as open62541's `UA_DataType_fromStructureDescription` computes it;
  every structure in `UA_TYPES` gets back the padding its C compiler gave it.
  A structure with an optional field is now registered as a structure with
  optional fields (the field a pointer, the body led by the encoding mask the
  Dart side already wrote): before, a client write to such a struct failed
  with `Bad_DecodingError`, and open62541 read a pointer out of the inline
  value while clearing the failed decode (a heap overflow under ASan).

- **Breaking: `Server.addVariableNode` adds a read-only node by default.**
  `accessLevel` defaulted to `AccessLevelMask(read: true, write: true)`, so
  every variable a server published without thinking about it was writable by
  any client that could connect, including the anonymous one the default
  server config admits. The default is now `AccessLevelMask(read: true)`: a
  client write to such a node is refused with `Bad_UserAccessDenied`
  (open62541 masks the node's AccessLevel into the session's UserAccessLevel
  and reports that one). `Server.write` is unaffected, the server's own
  writes bypass the access level. Migration, for every node clients are meant
  to write: `server.addVariableNode(id, value, accessLevel: const
  AccessLevelMask(read: true, write: true))`. `addDataSourceVariableNode` is
  unchanged, it has always derived write access from whether `onWrite` is
  given.
- **Fixed: a monitored sample the client could not decode was dropped
  without a trace.** The monitored-item data callback caught the conversion
  error, wrote one line to stderr and moved on; the consumer of `monitor`,
  `monitoredItems`, `monitorDataValue` or `monitoredDataValues` saw nothing,
  and a second later the backfill read of the item it never saw a sample for
  put the server's current value in its place. The error is now an error
  event on the stream (`addError`; a `String` once it has crossed the
  `ClientIsolate` boundary, like every non-status error), the stream stays
  open and the subscription stays up, so the next sample is delivered as
  before. `test/monitor_data_value_test.dart` (both clients): through the
  rewriting proxy a notification is turned into a Guid, a type this client
  has no conversion for; the error arrives on the stream without a value
  event, and a value written after the proxy stops rewriting is delivered
  on the same stream.
- **Build hook: archive extraction stays inside its directory.** The hook
  unpacks the open62541 zip and the mbedTLS tarball with a plain loop that
  wrote every entry at `extractDir/entry.name`, so an entry named
  `../../x` or `/etc/x`, or a symlink entry, would have landed wherever its
  name said. Both archives are checked against a pinned SHA-256 before
  extraction, so this only matters if that line falls; it now also skips
  symbolic links and refuses, naming the entry, any entry whose resolved
  path is not under the extract directory (`extractArchiveInto` in
  `hook/build.dart`, shared by both archives;
  `test/hook_extract_test.dart`). The dead `hook/ua_client_subscriptions.patch`
  is deleted: nothing referenced it, it does not apply to v1.5.9, and
  `_patchSubscriptionCleanup` has long done its job in code.
- **Fixed: `Server.asyncOperationTimeout` was 0, never, not the 2 minutes its
  dartdoc promised.** `UA_ServerConfig_setMinimal` sets the 2-minute default
  only under `UA_MULTITHREADING >= 100`, and this package builds
  single-threaded, so a parked method call or data-source write whose handler
  never completed stayed in flight for the life of the server, together with
  its output memory and its entry in the server's in-flight registries. The
  constructor now sets 2 minutes; the setter is unchanged for anyone who wants
  another deadline (`Duration.zero` is still "never").
  `test/server_async_timeout_test.dart`: a fresh `Server` reports 2 minutes,
  and (both clients) a data-source write whose handler never completes is
  answered Bad_Timeout by the server at a 1-second deadline, well before the
  client's own 5-second request timeout, with the server intact afterwards.
- **Security: the client verifies the server certificate; `Client` and
  `ClientIsolate.create` take `trustList`, `issuerList`, `revocationList`
  and `acceptAllCertificates`.** A client with a `certificate` called
  `UA_ClientConfig_setDefaultEncryption` with empty lists and then
  `UA_CertificateGroup_AcceptAll`: the channel was encrypted (safe from
  passive eavesdropping), the server never authenticated, any certificate
  opened the session. Now the lists (DER) go to open62541's in-memory
  certificate store: `trustList` holds the server certificates, or the CA
  certificates that issued them, to trust; `issuerList` intermediate CAs
  that complete a chain without being trusted themselves (installed through
  the store's `addToTrustList`, since `setDefaultEncryption` takes no issuer
  list); `revocationList` CRLs. open62541 verifies the server certificate
  before the channel opens and refuses a server that does not match:
  `BadCertificateUntrusted` for a certificate in no list,
  `BadCertificateChainIncomplete` for an issuer it cannot find,
  `BadCertificateRevoked` for one on a CRL. `acceptAllCertificates: true` is
  the explicit opt-out (encryption without authentication, open to an active
  attacker). open62541 copies the lists into its store, so the scratch
  memory is an arena freed after the calls; `test/client_trust_list_test.dart`
  measures the heap.
  - **Breaking for a client that passed a certificate and relied on
    accept-all:** a certificate with neither a non-empty `trustList` nor
    `acceptAllCertificates: true` is an `ArgumentError` (open62541 keeps the
    accept-all verification for an empty trust list, with only a warning in
    the log, so the safe behaviour has to be explicit). Migration: pass
    `trustList: [serverCertificateDer]`, or `acceptAllCertificates: true` to
    keep the old behaviour. The combinations are checked by
    `checkClientCertificateArguments`, also from `ClientIsolate.create` on
    the calling isolate; a certificate without its key (or the reverse), the
    lists or `acceptAllCertificates` without a certificate, and a trust list
    together with `acceptAllCertificates: true` are `ArgumentError`s too.
  - **`connect()` throws a `UaStatusException` when the handshake fails**
    (the connect status: a rejected server certificate, no endpoint for the
    security mode, a refused identity token) instead of waiting forever for
    an activation that cannot come: open62541 stops its state machine on a
    bad connect status and only another `connect()` restarts it. On
    `ClientIsolate` the exception crosses the isolate with its status code.
    `awaitConnect()` and `keepConnected()` are unchanged.
  - The bindings gain `UA_CreateCertificate`,
    `UA_ServerConfig_setDefaultWithSecurityPolicies` and the
    `UA_TrustListDataType` / `UA_KeyValuePair` structs (the tests build an
    encrypted open62541 server with them; the Dart `Server` has no security
    API).
- **Endpoint discovery: `Client.getEndpoints` (and `ClientIsolate.getEndpoints`)
  returns the server's endpoints with its certificate, for the trust list.**
  The question the trust list raises is where the server certificate comes
  from before the first secure connection; the OPC UA answer is the
  GetEndpoints service, which runs over a SecurityPolicy#None channel
  without a session and describes every endpoint with its
  `serverCertificate`. `getEndpoints(url, {timeout, logLevel})` needs no
  certificate and no trust list and keeps no state: a native client of its
  own for the call (`UA_Client_getEndpoints`: connect without a session,
  GetEndpoints, disconnect) on an isolate of its own, since the native call
  drives its own event loop and blocks until the answer; `ClientIsolate`
  gets the same static, as there is no session for a worker to hold. Each
  `EndpointDescription` has `endpointUrl`, `securityPolicyUri`,
  `securityMode`, `securityLevel`, `serverCertificate` (DER, empty for a
  server without one), `applicationUri`, `productUri`, `applicationName`,
  `transportProfileUri`, `userIdentityTokens` (`UserTokenPolicy`: policy id
  and `UserTokenType` anonymous/username/certificate/issued) and a
  `certificateThumbprint` (SHA-1 of the DER, uppercase hex, the thumbprint
  OPC UA tooling shows) to compare out of band. A host that does not answer
  within `timeout` is a `TimeoutException`; a refused connection, a bad URL
  or a Bad service result a `UaStatusException`. The trust-on-first-use
  flow (discover, confirm the thumbprint out of band, persist the DER, pass
  it as `trustList`, and why a MITM at discovery time is what the thumbprint
  check catches) is in README's Security section and the `Client` dartdoc;
  `example/discover_endpoints.dart` prints a server's endpoints and
  thumbprints. Bindings: `UA_Client_getEndpoints`, `UA_Array_delete`. The
  encrypted test server and client of `client_trust_list_test.dart` moved
  to `test/secure_fixtures.dart`, shared with
  `test/endpoint_discovery_test.dart`.
- **Docs: what the security of each side is.** README (Features, a Security
  section), `example/README.md`, the pubspec description and the `Client` /
  `ClientIsolate` dartdoc say that `SignAndEncrypt` authenticates the server
  only with a trust list, that accept-all is opt-in and protects against
  passive eavesdropping only, and that `allowUnencryptedPassword` sends the
  password in clear text. The `Server` dartdoc and README state what a
  `Server` is: SecurityPolicy None only, anonymous login with open62541's
  permissive default access control (any client can add/delete nodes and
  write any node whose access level allows it; `addVariableNode` defaults to
  read+write, `addDataSourceVariableNode` is read-only unless `onWrite` is
  given), bound on all interfaces, no API yet to change it, trusted networks
  only. `example/server_example.dart` carries the warning. The sentence
  about the ApplicationUri having to match the server certificate "once
  security is configured" is gone: a `Server` has no certificate. Server
  behaviour and defaults are unchanged.
- **`package:open62541/open62541_types.dart`: the value types without
  `dart:ffi`.** A new barrel exporting `DynamicValue`, `DynamicType`,
  `LocalizedText`, `EnumField`, `Schema` and `NodeId`, importable from code that
  must also compile for the browser (`flutter build web`, `dart compile js`).
  `NodeId` is split in two: `lib/src/node_id_core.dart` is the pure value type
  (the three identifier kinds, equality, every namespace-0 static such as
  `NodeId.serverStatusCurrentTime`, `NodeId.server`, `NodeId.namespaceArray`),
  and `lib/src/node_id.dart` keeps the FFI conversions as
  `extension NodeIdFfi on NodeId` and re-exports the core. The NS0 statics are
  literals in the core (reading `UA_NS0ID_*` from the generated bindings is
  what pulled `dart:ffi` in); `test/ns0_literals_test.dart` pins every one
  against its generated constant, and refuses a static added to the core
  without a row there. `test/web/types_web_test.dart` (`@TestOn('browser')`)
  compiles the barrel with dart2js, so a stray FFI import in the pure half
  fails CI instead of someone's web build. `dynamic_value.dart` now imports
  the core, which is what breaks the chain.
  - **Breaking for callers of `NodeId.fromRaw`:** it is `NodeIdFfi.fromRaw(...)`
    now (a static on the extension; a factory cannot live outside its class).
    `import 'package:open62541/open62541.dart'` exports `NodeIdFfi`, so the
    only change is the receiver name. `toRaw({allocator})` and `toRawPointer()`
    are unchanged for every caller: they are instance extension methods and
    resolve as before.
- **Fixed: `flutter build web` ran (or failed) the native build hook.** A web
  build asks the hook for no code assets, and there is nothing it could link
  for dart2js; it now returns before downloading or building open62541 when
  `input.config.buildCodeAssets` is false. Before, a Flutter web app that
  imported only `open62541_types.dart` either died in the hook (where
  `input.config.code` throws for a build without code assets) or sat through a
  full cmake build of a C library it can never call.
- **Fixed: a custom structure was an opaque ExtensionObject in UaExpert and
  asyncua.** The server encoded every ExtensionObject of a custom type
  (`addCustomType`) under the type's DataType id, while the DataType node's
  `DataTypeDefinition.defaultEncodingId` (which open62541 derives from the
  registered type) named a different id, and no node existed at either: a
  1.04 client matches the wire id against the `defaultEncodingId` it fetched
  (UaExpert, asyncua `load_data_type_definitions`) and found no type. The
  Dart client never noticed because it resolves the schema from the
  variable's DataType attribute. Now the wire carries the type's DefaultBinary
  DataTypeEncoding id, `addDataTypeNode` publishes the `Default Binary`
  object (TypeDefinition DataTypeEncodingType i=76, parentless as in NS0)
  and the HasEncoding (i=38) reference from the DataType node to it, and the
  encoding id follows the OPC UA naming convention: `ns=N;s=Name` →
  `ns=N;s=Name_Encoding_DefaultBinary` (a numeric id: `ns=N;i=42` →
  `ns=N;s=42_Encoding_DefaultBinary`; the rule is documented on
  `addCustomType`). Nested struct types auto-registered by `addCustomType`
  get theirs too. On the client, `readValue` and `Client.call` outputs (which
  have no DataType at hand) resolve the wire id to its DataType through the
  inverse HasEncoding reference, as a browser does; `read`, `readAttribute`
  and the monitors are unchanged. A write from a client that carries the
  encoding id is now decoded natively by open62541 and reaches a data-source
  `onWrite` through the native-struct path; one built from scratch under the
  DataType id decodes against the local schema as before. A definition
  fetched with `readAttribute(DATATYPEDEFINITION)` carries its
  `defaultEncodingId` as `extObjEncodingId`, so a value built from it
  (`DynamicValue.from`) writes with the encoding id the server expects.
  A bundled NS0 structure the reduced nodeset lacks as a node, published
  with `addDataTypeNode` (`NetworkGroupDataType` i=11944,
  `EndpointUrlListDataType` i=11943), gets its bundled `Default Binary`
  object (i=11958 / i=11957) via HasEncoding too. An ExtensionObject whose
  encoding id resolves to no DataType in the address space (a relayed value
  under a foreign id, a variable typed `BaseDataType`) is returned as its
  body with `extObjEncodingId` set by `readValue`, `read` and `Client.call`
  instead of failing (`Failed to read attribute: BadNodeIdUnknown` with the
  encoding id, or `Unsupported nodeId type: ns=0;i=24`); a Browse that
  fails for any other reason still throws. `NodeId.hasEncoding` and
  `NodeId.dataTypeEncodingType` are new.
- `ServerStatistics` gained `liveDataChangeNotificationCount` and
  `liveNotificationCount`: the per-subscription `dataChangeNotificationsCount`
  / `notificationsCount` (data changes + events; keep-alives carry none) of
  the NS0 SubscriptionDiagnosticsArray summed over the subscriptions alive
  right now (`null` without diagnostics). Lets a server derive its
  notification rate without hooking the publish path. Not cumulative since
  server start: a deleted subscription takes its share of the sum with it, so
  rate consumers difference the value and clamp a negative delta to zero.
- **`Server(applicationName:, applicationUri:, productName:, manufacturerName:, productUri:)`:
  the identity a server announces.** open62541's minimal config names every
  server `open62541-based OPC UA Application` with the ApplicationUri
  `urn:open62541.unconfigured.application`, which is what OPC UA browsers
  list it under (GetEndpoints/FindServers) and what `ServerArray[0]`,
  `NamespaceArray[1]` and `Server/ServerStatus/BuildInfo` report. The new
  constructor parameters replace those defaults on the config before the
  server is created (the defaults are freed, the copies are owned by the
  config and freed with it); `Server.applicationName` / `Server.applicationUri`
  / `Server.productUri` read them back. `productUri` sets both places
  open62541 keeps it, `ApplicationDescription.productUri` and
  `BuildInfo.productUri` (`Server/ServerStatus/BuildInfo/ProductUri`); left
  out it stays open62541's `http://open62541.org` even when `productName` /
  `manufacturerName` are set. Each one is opt-in: `Server()` still announces
  the defaults. A `Server` has no certificate (SecurityPolicy None only), so
  nothing checks the ApplicationUri against one.
- **Fixed: a hostile server could take the client down with one struct.** A
  struct's array member is sized from an Int32 the server put on the wire,
  and the deserializer cloned the member's template that many times before
  reading an element, with no bound: a 4-byte body claiming 2^31-1 elements
  was an uncatchable OutOfMemoryError (for `ClientIsolate`, the end of the
  isolate that owns the connection). Now a negative length is a null array
  (decoded as empty, Part 6), a length greater than the bytes left is refused
  with a `FormatException` at the length's offset before anything is sized by
  it (what open62541's `Array_decodeBinary` does), and the elements are
  decoded one at a time into a list that grows with them; the read fails and
  the client stays usable.
- **Fixed: a DataTypeDefinition that contained itself hung every read of the
  type.** `buildSchema` followed a field's DataType into its own definition
  with no memory of where it had been, so a type with a field of its own type
  (or A → B → A) was fetched forever, one readAttribute per level, and a
  `read`, `readValue`, `call` or monitor of such a value never completed.
  Now the chain of types being resolved travels down the recursion: a type
  met again fails the read with `DataTypeDefinitionCycle` naming the cycle,
  and more than 100 nested levels (open62541's own decoder bound) with
  `DataTypeDefinitionTooDeep`; both are exported, nothing of a refused schema
  is cached, and the client stays usable.
- **Fixed: a second `Client.keepConnected()` doubled the pump.** The call
  reset its stop flag and set it again synchronously, so the pump and the
  reconnect supervisor already running never observed the stop and kept
  going alongside the new pair: twice the `runIterate` calls per interval and
  two supervisors reconnecting. Each call now starts a new generation and the
  previous loops end on their next turn. `stopKeepConnected()` behaviour is
  unchanged.
- **Exported `UA_STATUSCODE_BADNODATA`, `UA_STATUSCODE_BADNODEIDUNKNOWN` and
  `UA_STATUSCODE_UNCERTAINLASTUSABLEVALUE`** from the package, next to the
  codes it already exported, so a data-source proxy can serve a quiet
  device's last usable value as Uncertain, or report "never had data", and
  a client can test a read for an unknown node, without reaching for the raw
  bindings.
- **Example: redundant METAR servers with ServiceLevel failover.**
  `example/metar_redundant_server.dart` publishes live weather for every
  Icelandic METAR station (`icelandMetarStations` in `metar_common.dart`,
  `--station` filters it) as a custom structured type, one data-source node
  per station named by its ICAO id (`ns=1;s=BIRK`) with every field of the
  structure as a HasComponent child generated from the schema
  (`ns=1;s=BIRK.TemperatureC`, ...), each carrying the struct's status and
  source timestamp (`onReadValue` — the last-known value is served
  `Bad_NoCommunication` when the feed is down, `Uncertain_LastUsableValue`
  when only the station has gone quiet, and a station that never reported
  reads `Bad_NoData`; none of which touches the ServiceLevel). It computes
  its `ServiceLevel` in the bands of OPC 10000-4 Table 105 (served through
  `Server.setVariableValueSource`), and publishes the hot-redundant set the
  Part 5 way through `Server.setRedundancy(RedundancySupport.hot,
  serverUris:, networkGroups:)`: `ServerRedundancy` typed
  `NonTransparentNetworkRedundancyType`, `ServerUriArray` holding the
  members' ApplicationUris (each instance announcing its own through
  `Server(applicationUri:)`) and `ServerNetworkGroups` mapping them to
  endpoints. It shuts down orderly with `Server.shutdown(delay:,
  announceServiceLevel: true)`. `example/metar_redundant_client.dart` is a
  Part 4 non-transparent redundant client seeded with ONE endpoint: it
  identifies the server by `ServerArray[0]`, reads `ServerUriArray` and
  `ServerNetworkGroups`, connects to the other members, polls every
  member's `ServiceLevel` and `ServerStatus.State` and switches by the Table
  105 bands (no failover from a Healthy server; a Degraded one is left for
  any Healthy one; a NoData member is polled but never given data; a
  Maintenance or shutting-down member is disconnected and retried much
  later). See `example/README.md` for what is spec-exact and what is
  simplified.

- **Known structures decode from their native layout.** A value whose
  DataType is a structure the bundled open62541 knows (every NS0 DataType in
  `UA_TYPES`: `ServerStatusDataType`, `BuildInfo`, `Argument`, `Range`,
  `EUInformation`, `NetworkGroupDataType`, ...) arrives decoded into the
  native struct, and `variantToValue` read that memory as an ExtensionObject
  header: `read`, `readValue`, `readAttribute`, `monitor` /
  `monitorDataValue`, `Client.call` outputs and `Server.read` of such a value
  failed (`Unknown value for UA_ExtensionObjectEncoding`, `Unsupported nodeId
  type: ns=0;i=862`, or a null check in `buildSchema`). The value is now
  walked by the type's `UA_DataTypeMember` table and comes out in the shape a
  custom type's ExtensionObject path produces: an object whose keys are the
  members' names (`StartTime`, `BuildInfo`, ... as in the type's
  DataTypeDefinition), nested objects, arrays (of structs and
  multi-dimensional ones too), optional fields (`isOptional`, null when
  absent), unions (an object holding the selected member), enums as Int32
  with the native enum's `enumFields`. Built-in members decode as before; a
  Guid is its text, a NodeId a `NodeId`, a LocalizedText a `LocalizedText`,
  a ByteString a `Uint8List`, an ExpandedNodeId / QualifiedName / DataValue
  / DiagnosticInfo an object of their fields, a nested Variant recursively,
  a nested ExtensionObject recursively when it is decoded, through its schema
  when one is at hand, and as its encoded bytes only for a type nobody knows.
  `typeId` is the type's id and `extObjEncodingId` its binary encoding id.
  An enum open62541 knows with no schema at hand (a method output,
  `Server.read`) decodes the same way instead of throwing.
- **An encoded ExtensionObject of a known structure decodes without a wire
  trip.** A value the Dart server published as a binary ExtensionObject (a
  `NetworkGroupDataType[]`, a `Range`) stays encoded in the server's own
  nodestore, and `Server.read` of it threw `Unsupported nodeId type:
  ns=0;i=22`, as did a nested encoded body with no schema. The encoding id is
  now looked up in `UA_TYPES`, the body decoded with `UA_decodeBinary` into a
  native struct in a scratch buffer, walked as above, and cleared and freed
  on every path; a body that does not decode is a `UaStatusException` with
  open62541's status. Bindings: `UA_decodeBinary`, `UA_clear` and
  `UA_DecodeBinaryOptions` added by hand in ffigen's form and listed in
  `tool/ffigen.dart` for the next regeneration; the options struct's size is
  pinned in `verify_sizes_test`. A custom type with no schema at hand keeps
  the previous behaviour.
- **A `DynamicValue` with an NS0 structure `typeId` can be written.**
  `valueToVariant` rejected a struct whose numeric `typeId` is not in the
  `Namespace0Id` enum (`Unknown Namespace0Id value: 884`), and an
  ExtensionObject encoded with the DataType id instead of the binary encoding
  id is not recognised by a receiver. A struct whose `typeId` is an NS0
  DataType the bundled open62541 knows (`Range` i=884, `NetworkGroupDataType`
  i=11944) is now encoded with that type's `_Encoding_DefaultBinary` id when
  `extObjEncodingId` is not set, so the Dart server can publish one (and a
  method return one) and a client reads it back decoded; an empty array of
  such a type travels as an empty ExtensionObject array. Custom types are
  encoded exactly as before.
- **Redundancy as a server feature: `Server.setRedundancy`** (#109). One
  call publishes a non-transparent redundant set the Part 5 way:
  `setRedundancy(RedundancySupport.hot, serverUris: [...])` creates
  `NonTransparentRedundancyType` (`i=2039`, a subtype of
  `ServerRedundancyType` with the mandatory `ServerUriArray` property) if
  the address space lacks it (open62541's reduced NS0 does), retypes
  `Server/ServerRedundancy` (`i=2296`) to it, serves `RedundancySupport`
  (`i=3709`) through the value-source takeover and adds `ServerUriArray`
  (`i=11314`, `0:ServerUriArray` of `PropertyType`, a String array with
  ValueRank 1 and ArrayDimensions `[0]`, as is the declaration). Calling it
  again updates the mode and the array in place; `RedundancySupport.none`
  puts the object back on the base type and removes the array, so a non-NONE
  mode on the base type (Part 5 §6.3.7) is not reachable through the API.
  An empty `serverUris`, URIs with `none`, and `transparent` (which calls
  for `TransparentRedundancyType`, not modelled) throw `ArgumentError`
  before anything changes. Part 5 wants *server URIs* (application URIs)
  and §6.3.9 the local server among them: the server's own ApplicationUri
  (`applicationDescription.applicationUri`) is prepended when the list does
  not contain it. Works before `start()` too: open62541 deletes the standard
  `ServerUriArray` when the server is created, not at startup. The new
  `RedundancySupport` enum carries the Part 5 values (0..5). Built on two
  generic additions:
  - **`Server.addObjectTypeNode`**: a custom ObjectType, subtype of
    `BaseObjectType` or of a given type, abstract or not. Its mandatory
    children are ordinary `addVariableNode` / `addObjectNode` children of the
    type node carrying a `HasModellingRule` reference to `Mandatory` (`i=78`,
    `addReference`); `addObjectNode(typeDefinition: ...)` copies them onto
    every instance, as the dartdoc example shows. Throws `UaStatusException`.
  - **`Server.setTypeDefinition`**: retypes an existing object (NS0 ones
    included) by replacing its `HasTypeDefinition` reference; open62541
    enforces no model constraint on that reference, so no delete-and-re-add
    is needed. Nothing is instantiated or removed. `Bad_NodeIdUnknown` /
    `Bad_TypeDefinitionInvalid` before anything changes; a no-op for the
    current type.
  - **`Server.deleteReference`**: the counterpart of `addReference`.
  - Bindings: `UA_Server_browse`, `UA_clear` and `UA_ObjectTypeAttributes`
    added by hand in ffigen's form and listed in `tool/ffigen.dart` for the
    next regeneration; their sizes are pinned in `verify_sizes_test`.
  - `Client.readAttribute` reads `ValueRank` and `ArrayDimensions` (one of
    them per call; both land in the value).
  - **`setRedundancy(..., networkGroups:)` publishes `ServerNetworkGroups`**
    (Part 5 §6.3.10), so a client can find every member of the set from one
    of them: a ServerUri is an identity, and this property is the spec's map
    from it to endpoints. Given `Map<String serverUri, List<String>
    endpointUrls>`, the call types `ServerRedundancy` as
    `NonTransparentNetworkRedundancyType` (`i=11945`, created as a subtype of
    `NonTransparentRedundancyType` with the mandatory `ServerNetworkGroups`
    declaration `i=11948`) and adds `ServerNetworkGroups` (`i=14415`, a
    `NetworkGroupDataType[]` of `PropertyType`, ValueRank 1): one group per
    `ServerUriArray` entry, in its order, with that member's URLs as its
    single network path (an `EndpointUrlListDataType`; a member mapped to
    `[]` has no path). The map's keys must be exactly the members, the local
    ApplicationUri included (`ArgumentError` naming the stranger or the
    missing member, before anything changes). The DataType nodes
    `EndpointUrlListDataType` (`i=11943`) and `NetworkGroupDataType`
    (`i=11944`), absent from the reduced NS0 though open62541 knows both
    types, are added as `Structure` subtypes with `0:` names, so the
    property's DataType and DataTypeDefinition read as Part 5 says. Calling
    again updates the groups in place; a call without `networkGroups` removes
    the property and types the object `NonTransparentRedundancyType` again;
    `none` removes both properties. The value is read back decoded on both
    client types and by `Server.read`, which the native-layout decoding
    above makes possible.
- **Orderly shutdown: `Server.shutdown(delay:)` and `Server.shutdownDelay`.**
  With a delay the server first announces the shutdown, keeps serving for
  the delay, then shuts down: during the delay `ServerStatus.State`
  (`i=2259`) reads `Shutdown` (4) and `SecondsTillShutdown` (`i=2992`)
  counts down, the Part 5 §12.6 hand-off signal for clients of a redundant
  set, while reads, writes, calls and subscriptions are served as before.
  The call blocks the calling isolate for the delay (rounded up to whole
  seconds, the unit of the announcement) and pumps open62541 itself; the
  no-argument `shutdown()` is unchanged. A redundant server passes
  `announceServiceLevel: true` to serve `ServiceLevel` 0 for the delay, the
  Part 4 Table 105 signal for the clients of a redundant set to leave; it
  replaces the ServiceLevel value source (open62541's constant 255, which
  refuses writes with `Bad_WriteNotSupported`, or the server's own from
  `setVariableValueSource`). `shutdownDelay` is
  `UA_ServerConfig.shutdownDelay`; `shutdown()` honours it and `shutdown(delay:)`
  sets it. Why not open62541's own delayed shutdown: `UA_Server_run_shutdown`
  ignores `shutdownDelay` and stops the listeners at once; the delay is
  implemented only inside `UA_Server_run`, the blocking loop this binding
  does not use. The announcement that loop makes is reachable from outside:
  a local write of `SecondsTillShutdown` sets the server's end time, from
  which open62541's ServerStatus value source derives the state and the
  countdown (`src/server/ua_server_ns0.c`).

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
  `serverRedundancy`, `redundancySupport`, `serverUriArray`,
  `serverNetworkGroups`, `organizes`, `hasComponent`, `hasProperty`,
  `hasTypeDefinition`, `baseObjectType`, `folderType`,
  `baseDataVariableType` and `propertyType` join the existing folder and
  reference-type statics, each backed by the generated constant
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
- **Build: mbedTLS 3.6.5 → 3.6.7.** The bundled TLS library moves to the
  current 3.6 LTS release, which closes, among the advisories of 3.6.6 and
  3.6.7: CVE-2026-25835 (the random generator state was duplicated across
  `fork()`, so parent and child drew the same bytes; the child now reseeds),
  CVE-2026-34874 (NULL dereference in `mbedtls_x509_string_to_names()` when
  an allocation fails) and CVE-2026-49300 (two X.509 parser bugs accepted a
  malformed `basicConstraints` extension, so a certificate other
  implementations treat as end-entity could parse as a CA). 3.6.6 also moved
  the Linux fallback entropy device from `/dev/urandom` to `/dev/random`;
  immaterial here, `getrandom()` is used wherever it exists. The release
  asset's SHA-256 is pinned as before (verified against the sum published on
  the release page); a warm `.dart_tool` re-downloads and rebuilds mbedTLS
  once on the next build, as described above.
- **Build: the native library is compiled and linked with hardening flags.**
  open62541 and the mbedTLS linked into it are built, per toolchain, with
  GCC/clang `-fstack-protector-strong -D_FORTIFY_SOURCE=2` (a canary in every
  frame that holds an array; bounded `__*_chk` libc calls wherever the
  compiler knows the destination size — active, since the build is
  Release/-O3) and, on Linux and Android, linked with `-Wl,-z,relro,-z,now`
  (full RELRO: the GOT is resolved at load and then read-only, so a write
  primitive cannot redirect a call through it); MSVC gets `/GS /guard:cf`
  and the DLL `/DYNAMICBASE /NXCOMPAT /guard:cf`. The toolchain follows the
  target OS the way the build does (Visual Studio for a Windows target, the
  NDK and Xcode toolchain files otherwise), not the host.
  `test/native_hardening_test.dart` (Linux) reads the ELF the VM loaded and
  asserts BIND_NOW with a GNU_RELRO segment, a FORTIFY `__*_chk` import and
  `__stack_chk_fail`; skipped where `readelf`/`nm` are absent. The mbedTLS
  install prefix is now stamped with the flags it was built under and
  rebuilt on a mismatch, so a warm `.dart_tool` does not keep linking an
  install built without them (one rebuild on the first build after this
  upgrade). The sanitizer switch for CI's ASan job is renamed from
  `ENABLE_SANITIZER` to `OPEN62541_DART_SANITIZER`; its flags go on top of
  the hardening ones.
- **CI: actions pinned to commit SHAs, read-only token, the iOS job can
  fail.** Every `uses:` in `run_tests.yml` and `flutter_test.yml` names the
  full commit of the release it resolved to (`actions/checkout` v7.0.1,
  `dart-lang/setup-dart` v1.8.1, `subosito/flutter-action` v2.23.0,
  `actions/setup-java` v6.1.0, `reactivecircus/android-emulator-runner`
  v2.38.0), with the version as a trailing comment; Dependabot's
  `github-actions` entry keeps the pins current. Both workflows run with
  `permissions: contents: read`. The iOS job's `flutter test ... || true`
  reported every run green; the step now fails with the test (`pipefail`
  through the `tee`), and the output tail and crash-log listing moved to a
  step that runs on failure.
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
