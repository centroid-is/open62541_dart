# Integration suite — shared context for test-authoring agents

You are writing one category of a local robustness/correctness integration suite
for a Dart OPC UA library (FFI bindings to open62541). Target domain: **HMI
systems for industrial fish production** (tanks, sensors, setpoints, alarms).
Everything runs **locally** (no GitHub CI). The branch is `integration-test-suite`.

## Harness API (test/integration/harness/) — reuse this, do not modify it

- `reference_server.dart` — `ReferenceServer.asyncuaFishFarm({required int port, int tanks=3, bool live=true, int updateMs=250})`, `.nodeOpcuaFishFarm({...})`. Methods: `Future start()`, `Future stop({signal})` (SIGKILL = crash), `Future restart({Duration downtime})`, getters `port`, `endpoint`, `isRunning`.
- `toxiproxy.dart` — `Toxiproxy.start()` → then `createProxy({required String upstreamHost, required int upstreamPort, int? listenPort})` → `ToxiProxyHandle`. Handle: `url` (`opc.tcp://127.0.0.1:<listen>`), `addLatency({required Duration latency, Duration jitter, String stream})`, `addBandwidth({required int kbps})`, `addTimeout({Duration after})`, `addResetPeer({Duration after})`, `addSlicer({required int averageSize, int delayMicros})`, `removeToxic(name)`, `reset()` (remove all toxics), `disable()`/`enable()` (drop/restore link). `Toxiproxy.stop()` cleans up.
- `dart_client.dart` — `connectClient(String url, {ClientKind kind = ClientKind.direct, LogLevel logLevel, Duration iterate, Duration connectTimeout})` → `DrivenClient` (`.client` is a `ClientApi`, `.kind`, `Future dispose()`). `clientTypes` = `[ClientKind.direct, ClientKind.isolate]` — parameterize groups over both when relevant.
- `browse_resolver.dart` — `resolvePath(ClientApi, List<String> path, {NodeId? root})`, `tankVar(client, int tank, String name)`, `tankMethod(client, tank, name)`, `resolveAll(...)`. Resolves by BrowseName (namespace-index agnostic).
- `net.dart` — `Future<int> freePort()`. **Always use this for server/proxy ports.**
- `paths.dart` — `asyncuaAvailable()`, `nodeOpcuaAvailable()`, `toxiproxyAvailable()`. **Skip-guard every test group** on the deps it needs.

## Reference-server fish-farm model (asyncua & node-opcua)

Browse path from Objects: `Plant/Tank{i}/<var>`. Per tank:
`Temperature, DissolvedOxygen, PH, Salinity, WaterLevel` (Double sensors, live),
`TempSetpoint` (Double, writable), `PumpRunning` (Boolean, writable),
`AlarmActive` (Boolean), `AlarmMessage` (String), `AlarmSeverity` (UInt16),
methods `FeedNow(grams: Double) -> Boolean` and `ResetAlarm() -> Boolean`.

## Dart library API essentials

- `Client`/`ClientIsolate` both implement `ClientApi`: `connect(url)`, `awaitConnect()`, `read(NodeId) -> DynamicValue`, `write(NodeId, DynamicValue)`, `readAttribute(Map<NodeId,List<AttributeId>>)`, `subscriptionCreate({Duration requestedPublishingInterval, ...}) -> int`, `monitor(NodeId, int subId, {Duration samplingInterval, ...}) -> Stream<DynamicValue>`, `monitoredItems(map, subId, {...}) -> Stream<Map<NodeId,DynamicValue>>`, `browse(NodeId, {...})`, `browseTree(...)`, `call(NodeId objectId, NodeId methodId, Iterable<DynamicValue>) -> List<DynamicValue>`, `stateStream`, `delete()`. Monitored-item streams emit errors `Inactivity`, `SubscriptionDeleted`, `SecureChannelClosed` (from `types/errors.dart`) on disconnect/loss.
- `Server` (own OPC UA server, use for Dart-server-side tests): `Server({LogLevel? logLevel, int? port})`, `.start()`, `.addVariableNode(NodeId, DynamicValue, {AccessLevelMask, NodeId? parentNodeId, ...})` (value needs `.name` = browse name), `.addVariableTypeNode`, `.addDataTypeNode`, `.addCustomType(NodeId typeId, DynamicValue)`, `.write(NodeId, DynamicValue)`, `.read(NodeId)`, `.writeDescription`, `.runIterate()`, `.shutdown()`, `.delete()`. **No method or object nodes** — for method/event tests use the reference servers. Drive it with a loop like `test/common.dart` `setupServer` (`while (server.runIterate()) await Future.delayed(50ms)`).
- `DynamicValue({dynamic value, NodeId? typeId, String? name, LocalizedText? description, LocalizedText? displayName})`; indexing `v[i]` (array) / `v["field"]` (struct); `.asDouble/.asInt/.asString/.asBool/.asArray/.asObject/.isArray/.isObject`; `DynamicValue.fromList(list, {typeId, name})`, `DynamicValue.fromMap`. Enums = int scalar + `enumFields`. Assigning a plain (unordered) `Map` throws — build objects field by field or via `fromMap(LinkedHashMap)`.
- `NodeId.fromString(int ns, String id)`, `NodeId.fromNumeric(int ns, int id)`, statics `NodeId.boolean/int32/uint32/int64/double/float/byte/uastring/datetime/...`, `NodeId.objectsFolder`.
- Existing patterns to mirror: `test/common.dart` (setupServer/setupClient), `test/async_integration_test.dart`, `test/subscription_deleted_test.dart`.

## Known library limitations (likely to be surfaced as failing tests → targets)

- Multi-dimensional array **struct members** decode as empty (`lib/src/types/opcua_serializer.dart:178-188`, only 1-D dims built).
- Struct **field descriptions** don't surface.
- **Optional struct fields** throw `'Optional values not supported currently'` (`opcua_serializer.dart:39`).
- Only **int32 enums** supported (`opcua_serializer.dart:168`).
- NodeId **GUID/ByteString** unimplemented (`node_id.dart:39`).
- Already skipped/failing in-repo: `multi_client` basic read/write, `async_integration` "struct of strings", "Array of struct read and write".

## Rules

1. Write test files ONLY under your category dir `test/integration/<category>/`. Do NOT modify the harness, the library (`lib/`), or other categories.
2. Every test file starts with `@Tags(['integration'])` + `library;`, and every group is skip-guarded on the deps it uses (`asyncuaAvailable()`, `toxiproxyAvailable()`, `nodeOpcuaAvailable()`).
3. Always use `freePort()` for ports. Give network/chaos tests generous timeouts.
4. **Do NOT fix library bugs.** When a test reveals a genuine library bug, keep the test but mark it `skip: 'BUG: <one-line root cause>'` so the suite stays green, and record it in your findings.
5. Before declaring a failure a real bug, re-run that single test in isolation (`dart test -j 1 -n "<name>" test/integration/<category>/<file>`) to rule out contention flakiness (the machine is shared with other agents).
6. Run your suite serially: `dart test -j 1 test/integration/<category>`. Ensure `dart analyze test/integration/<category>` is clean and `dart format test/integration/<category>` applied.
7. Commit your work on the current branch with a clear message (do not push).

## Return in your final report

- Test files created (paths) and what each covers.
- Pass / fail / quarantined counts.
- For every failure or quarantine: root-cause analysis — **library bug** (cite file:line) vs test issue vs flake — this feeds the fix-branch triage.
