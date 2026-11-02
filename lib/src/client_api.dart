import 'client.dart';
import 'dynamic_value.dart';
import 'extensions.dart';
import 'node_id.dart';
import 'types/errors.dart';

abstract class ClientApi {
  /// Waits until the client session is fully activated.
  Future<void> awaitConnect();

  /// Connects to an OPC UA server at [url] and waits for session activation.
  /// Do remember that runIterate is needed to be called after connect.
  Future<void> connect(String url);

  /// Writes [value] to the node identified by [nodeId].
  Future<void> write(NodeId nodeId, DynamicValue value);

  /// Stream of client state changes (channel state, session state, connect status).
  Stream<ClientState> get stateStream;

  /// Reads the value, display name, description, and data type of [nodeId].
  Future<DynamicValue> read(NodeId nodeId);

  /// Reads the Value attribute of [nodeId] as a full [DataValue]: the decoded
  /// value plus the operation's OPC UA status code and source/server
  /// timestamps. A non-Good operation status is returned (not thrown), so
  /// callers can observe quality (e.g. `Bad_NoCommunication`) alongside a
  /// last-known value.
  Future<DataValue> readValue(NodeId nodeId);

  /// Reads multiple attributes from multiple nodes in a single service call.
  Future<Map<NodeId, DynamicValue>> readAttribute(ReadAttributeParam nodes);

  /// Creates a subscription on the server.
  ///
  /// Returns the subscription ID to be used with [monitor].
  Future<int> subscriptionCreate({
    Duration requestedPublishingInterval = const Duration(milliseconds: 100),
    int requestedLifetimeCount = 10000,
    int requestedMaxKeepAliveCount = 10,
    int maxNotificationsPerPublish = 0,
    bool publishingEnabled = true,
    int priority = 0,
  });

  /// Monitors a single node for data changes.
  ///
  /// Returns a stream that emits the latest value whenever it changes.
  /// Requires a [subscriptionId] from [subscriptionCreate].
  Stream<DynamicValue> monitor(
    NodeId nodeId,
    int subscriptionId, {
    MonitoringMode monitoringMode = MonitoringMode.UA_MONITORINGMODE_REPORTING,
    Duration samplingInterval = const Duration(milliseconds: 100),
    bool discardOldest = true,
    int queueSize = 1,
  });

  /// Monitors multiple nodes and attributes for data changes.
  ///
  /// Returns a stream that emits a map of node values whenever any
  /// monitored value changes. Requires a [subscriptionId] from
  /// [subscriptionCreate].
  Stream<Map<NodeId, DynamicValue>> monitoredItems(
    ReadAttributeParam nodes,
    int subscriptionId, {
    MonitoringMode monitoringMode = MonitoringMode.UA_MONITORINGMODE_REPORTING,
    Duration samplingInterval = const Duration(milliseconds: 100),
    bool discardOldest = true,
    int queueSize = 1,
  });

  /// Browses the references of a node.
  ///
  /// Returns the list of references from [nodeId]. Handles continuation
  /// points automatically (BrowseNext) for nodes with many references.
  ///
  /// - [direction]: 0 = forward, 1 = inverse, 2 = both.
  /// - [referenceTypeId]: filter by reference type, e.g. [NodeId.hierarchicalReferences].
  ///   Pass null for all reference types.
  /// - [includeSubtypes]: include subtypes of [referenceTypeId].
  /// - [nodeClassMask]: bitmask to filter by node class. 0 = all classes.
  ///   Combine with `|`, e.g. `NodeClass.UA_NODECLASS_OBJECT.value | NodeClass.UA_NODECLASS_VARIABLE.value`.
  /// - [resultMask]: bitmask controlling which fields are returned.
  ///   Use [BrowseResultMask] enum. Defaults to [BrowseResultMask.UA_BROWSERESULTMASK_ALL].
  Future<List<BrowseResultItem>> browse(
    NodeId nodeId, {
    int direction = 0,
    NodeId? referenceTypeId,
    bool includeSubtypes = true,
    int nodeClassMask = 0,
    BrowseResultMask resultMask = BrowseResultMask.UA_BROWSERESULTMASK_ALL,
  });

  /// Recursively walks the address space tree starting from [root].
  ///
  /// Returns a stream of [BrowseTreeItem] that includes the browse result,
  /// the depth in the tree, and the parent node ID. Results are emitted
  /// incrementally as the tree is walked (depth-first).
  ///
  /// - [maxDepth]: maximum recursion depth. Defaults to 100.
  /// - [referenceTypeId]: filter by reference type, e.g. [NodeId.hierarchicalReferences].
  /// - [includeSubtypes]: include subtypes of [referenceTypeId].
  /// - [recurseInto]: set of node classes to recurse into.
  ///   Defaults to objects and views. Nodes with other classes are emitted
  ///   but not expanded.
  ///
  /// Cycle-safe: tracks visited nodes and will not revisit them.
  Stream<BrowseTreeItem> browseTree(
    NodeId root, {
    int maxDepth = 100,
    NodeId? referenceTypeId,
    bool includeSubtypes = true,
    Set<NodeClass> recurseInto = const {NodeClass.UA_NODECLASS_OBJECT, NodeClass.UA_NODECLASS_VIEW},
  });

  /// Calls a method on the server.
  ///
  /// [objectId] is the node hosting the method, [methodId] is the method node,
  /// and [args] are the input arguments.
  Future<List<DynamicValue>> call(NodeId objectId, NodeId methodId, Iterable<DynamicValue> args);

  /// Disconnects and releases all resources.
  Future<void> delete();
}

/// Monitoring with quality: every sample as a [DataValue], carrying the status
/// code and the source/server timestamps the server attached to it.
///
/// A separate interface, not new members of [ClientApi]: Dart requires a class
/// that `implements` an interface to define every member of it, bodies
/// included, so there is no way to add a member to [ClientApi] that a class
/// written against today's [ClientApi] (a wrapper, a test fake) would survive.
/// [Client] and `ClientIsolate` implement both. Code that holds a [ClientApi]
/// checks `is DataValueMonitoringApi` to reach these.
///
/// [ClientApi.monitor] / [ClientApi.monitoredItems] are unchanged: they deliver
/// the value alone, and put a sample with a non-Good status on the stream as a
/// [UaStatusException] error, delivering nothing for it.
abstract class DataValueMonitoringApi {
  /// Monitors the Value attribute of [nodeId] (with its DataType, Description
  /// and DisplayName, like [ClientApi.monitor]) and emits every sample as a
  /// [DataValue].
  ///
  /// Each event is a fresh [DataValue] over a fresh copy of the value, on
  /// [Client] as on `ClientIsolate`: a consumer may keep it. See
  /// [monitoredDataValues] for what a sample's status and timestamps become.
  /// Requires a [subscriptionId] from [ClientApi.subscriptionCreate].
  Stream<DataValue> monitorDataValue(
    NodeId nodeId,
    int subscriptionId, {
    MonitoringMode monitoringMode = MonitoringMode.UA_MONITORINGMODE_REPORTING,
    Duration samplingInterval = const Duration(milliseconds: 100),
    bool discardOldest = true,
    int queueSize = 1,
  });

  /// Monitors multiple nodes and attributes, like [ClientApi.monitoredItems],
  /// and emits a map of [DataValue] per node whenever any monitored value
  /// changes. Requires a [subscriptionId] from [ClientApi.subscriptionCreate].
  ///
  /// A sample of the **Value** attribute is delivered whatever its status:
  ///
  /// - [DataValue.statusCode] is the server's own code (`UA_STATUSCODE_GOOD`,
  ///   0, when the notification carries none). Uncertain is a status like any
  ///   other; tell them apart with [DataValue.isGood], [DataValue.isUncertain]
  ///   and [DataValue.isBad].
  /// - A sample that carries a value is decoded like any other, Bad or not.
  ///   A sample with a non-Good status and no value keeps the last known
  ///   value (an empty [DynamicValue] when there is none yet). A Good sample
  ///   with no value says the Value is empty now: the value is null.
  /// - [DataValue.sourceTimestamp] and [DataValue.serverTimestamp] are the
  ///   notification's own, null when it carries none or carries the OPC UA
  ///   null timestamp (tick 0). A sample never keeps the previous sample's.
  ///
  /// Only the Value attribute has a status to deliver. A Bad sample of any
  /// other monitored attribute is added to the stream as a [UaStatusException]
  /// error, and does not hold the map back. A node whose Value attribute is
  /// not monitored reports `UA_STATUSCODE_GOOD` and no timestamps.
  ///
  /// Each event is a fresh map of fresh [DataValue] objects over fresh copies
  /// of the values, on [Client] as on `ClientIsolate`: a consumer may keep
  /// them, or compare one event with the next.
  Stream<Map<NodeId, DataValue>> monitoredDataValues(
    ReadAttributeParam nodes,
    int subscriptionId, {
    MonitoringMode monitoringMode = MonitoringMode.UA_MONITORINGMODE_REPORTING,
    Duration samplingInterval = const Duration(milliseconds: 100),
    bool discardOldest = true,
    int queueSize = 1,
  });
}

/// Historical Access (OPC UA Part 11): reading a node's stored history with
/// the HistoryRead service.
///
/// A separate interface, like [DataValueMonitoringApi]: adding members to
/// [ClientApi] would break every class that implements it. [Client] and
/// `ClientIsolate` implement it; code that holds a [ClientApi] checks
/// `is HistoryReadApi`.
abstract class HistoryReadApi {
  /// Reads the raw history of [nodeIds] (ReadRawModifiedDetails) between
  /// [start] and [end], and returns each node's values in the server's order
  /// (oldest first, or newest first when [start] is after [end]).
  ///
  /// [start] and [end] left `null` are unspecified (Part 11 then needs
  /// [numValuesPerNode] and the other bound). [numValuesPerNode] is the most
  /// values per node in one response, `0` for the server's choice; the
  /// server answers more in pages, and this follows their continuation
  /// points until every node is done (an empty page with a continuation
  /// point is followed too). [maxValues] stops a node after that many values:
  /// the result keeps the first [maxValues] and the server is told to release
  /// the node's continuation point. [returnBounds] asks for the bounding
  /// values; [timestampsToReturn] for the source timestamps (default), the
  /// server's or both (`neither` is refused by the server with
  /// `Bad_TimestampsToReturnInvalid`).
  ///
  /// Each [DataValue] carries the value's own status and the requested
  /// timestamps. A node answered with a Bad status (`Bad_NodeIdUnknown`,
  /// `Bad_HistoryOperationInvalid`, ...) fails the call with a
  /// [UaStatusException] carrying it, as does a Bad service result; the
  /// continuation points still held are released first. A repeated NodeId
  /// is read once.
  Future<Map<NodeId, List<DataValue>>> historyReadRaw(
    List<NodeId> nodeIds, {
    DateTime? start,
    DateTime? end,
    int numValuesPerNode = 0,
    int? maxValues,
    bool returnBounds = false,
    TimestampsToReturn timestampsToReturn = TimestampsToReturn.UA_TIMESTAMPSTORETURN_SOURCE,
  });
}
