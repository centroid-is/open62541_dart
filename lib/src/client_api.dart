import 'client.dart';
import 'dynamic_value.dart';
import 'extensions.dart';
import 'node_id.dart';

abstract class ClientApi {
  Future<void> awaitConnect();

  Future<void> connect(String url);

  Future<void> write(NodeId nodeId, DynamicValue value);

  Stream<ClientState> get stateStream;

  Future<DynamicValue> read(NodeId nodeId);

  Future<Map<NodeId, DynamicValue>> readAttribute(ReadAttributeParam nodes);

  Future<int> subscriptionCreate({
    Duration requestedPublishingInterval = const Duration(milliseconds: 100),
    int requestedLifetimeCount = 10000,
    int requestedMaxKeepAliveCount = 10,
    int maxNotificationsPerPublish = 0,
    bool publishingEnabled = true,
    int priority = 0,
  });

  Stream<DynamicValue> monitor(
    NodeId nodeId,
    int subscriptionId, {
    MonitoringMode monitoringMode = MonitoringMode.UA_MONITORINGMODE_REPORTING,
    Duration samplingInterval = const Duration(milliseconds: 100),
    bool discardOldest = true,
    int queueSize = 1,
  });

  Future<List<DynamicValue>> call(NodeId objectId, NodeId methodId, Iterable<DynamicValue> args);

  Future<void> delete();
}
