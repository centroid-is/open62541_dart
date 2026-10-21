// A class written against ClientApi as it is on main must keep compiling.
//
// Monitoring with quality (DataValueMonitoringApi: monitorDataValue and
// monitoredDataValues) is a SEPARATE interface, not new members of ClientApi.
// Dart requires a class that `implements` an interface to define every member
// of it, bodies included, so any member added to ClientApi — abstract or with
// a default body — breaks every wrapper and test fake out there with
// `missing_override` at their next analysis. This fake declares exactly the
// members ClientApi has on main; if ClientApi grows a member, this file stops
// compiling, which is the point.

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';

/// Exactly ClientApi's members, as a downstream wrapper or test fake has them.
class MainClientApiFake implements ClientApi {
  @override
  Future<void> awaitConnect() async {}

  @override
  Future<void> connect(String url) async {}

  @override
  Future<void> write(NodeId nodeId, DynamicValue value) async {}

  @override
  Stream<ClientState> get stateStream => const Stream.empty();

  @override
  Future<DynamicValue> read(NodeId nodeId) async => DynamicValue();

  @override
  Future<DataValue> readValue(NodeId nodeId) async => DataValue(value: DynamicValue(), statusCode: UA_STATUSCODE_GOOD);

  @override
  Future<Map<NodeId, DynamicValue>> readAttribute(Map<NodeId, List<AttributeId>> nodes) async => {};

  @override
  Future<int> subscriptionCreate({
    Duration requestedPublishingInterval = const Duration(milliseconds: 100),
    int requestedLifetimeCount = 10000,
    int requestedMaxKeepAliveCount = 10,
    int maxNotificationsPerPublish = 0,
    bool publishingEnabled = true,
    int priority = 0,
  }) async => 1;

  @override
  Stream<DynamicValue> monitor(
    NodeId nodeId,
    int subscriptionId, {
    MonitoringMode monitoringMode = MonitoringMode.UA_MONITORINGMODE_REPORTING,
    Duration samplingInterval = const Duration(milliseconds: 100),
    bool discardOldest = true,
    int queueSize = 1,
  }) => const Stream.empty();

  @override
  Stream<Map<NodeId, DynamicValue>> monitoredItems(
    Map<NodeId, List<AttributeId>> nodes,
    int subscriptionId, {
    MonitoringMode monitoringMode = MonitoringMode.UA_MONITORINGMODE_REPORTING,
    Duration samplingInterval = const Duration(milliseconds: 100),
    bool discardOldest = true,
    int queueSize = 1,
  }) => const Stream.empty();

  @override
  Future<List<BrowseResultItem>> browse(
    NodeId nodeId, {
    int direction = 0,
    NodeId? referenceTypeId,
    bool includeSubtypes = true,
    int nodeClassMask = 0,
    BrowseResultMask resultMask = BrowseResultMask.UA_BROWSERESULTMASK_ALL,
  }) async => [];

  @override
  Stream<BrowseTreeItem> browseTree(
    NodeId root, {
    int maxDepth = 100,
    NodeId? referenceTypeId,
    bool includeSubtypes = true,
    Set<NodeClass> recurseInto = const {NodeClass.UA_NODECLASS_OBJECT, NodeClass.UA_NODECLASS_VIEW},
  }) => const Stream.empty();

  @override
  Future<List<DynamicValue>> call(NodeId objectId, NodeId methodId, Iterable<DynamicValue> args) async => [];

  @override
  Future<void> delete() async {}
}

void main() {
  test('a ClientApi implementation with exactly main\'s members compiles and is not a DataValueMonitoringApi', () {
    // Compiling this file is the test. The runtime checks keep it from being
    // vacuous: the fake IS a ClientApi, and it does NOT get the quality
    // surface for free — that lives on its own interface.
    final ClientApi api = MainClientApiFake();
    expect(api, isA<ClientApi>());
    expect(api, isNot(isA<DataValueMonitoringApi>()));
  });

  test('Client and ClientIsolate carry the quality surface next to ClientApi', () async {
    // Static: both assignments must type-check without a cast.
    final Client direct = Client();
    final DataValueMonitoringApi directQuality = direct;
    expect(directQuality, same(direct));
    await direct.delete();

    final isolate = await ClientIsolate.create();
    final DataValueMonitoringApi isolateQuality = isolate;
    expect(isolateQuality, same(isolate));
    await isolate.delete();
  });
}
