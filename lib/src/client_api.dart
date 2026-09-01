import 'client.dart';
import 'dynamic_value.dart';
import 'extensions.dart';
import 'node_id.dart';

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
  ///
  /// Emitted values carry [DynamicValue.statusCode] and
  /// [DynamicValue.sourceTimestamp] as the server sent them. See
  /// [deliverBadStatus] for what happens to a sample the server marked Bad.
  Stream<DynamicValue> monitor(
    NodeId nodeId,
    int subscriptionId, {
    MonitoringMode monitoringMode = MonitoringMode.UA_MONITORINGMODE_REPORTING,
    Duration samplingInterval = const Duration(milliseconds: 100),
    bool discardOldest = true,
    int queueSize = 1,
    bool deliverBadStatus = false,
  });

  /// Monitors multiple nodes and attributes for data changes.
  ///
  /// Returns a stream that emits a map of node values whenever any
  /// monitored value changes. Requires a [subscriptionId] from
  /// [subscriptionCreate].
  ///
  /// [deliverBadStatus] decides what a sample the server marked Bad becomes,
  /// and defaults to **false** — the behaviour this binding has had for years.
  ///
  /// - `false`: the sample is DROPPED and its status is added to the stream as
  ///   an error string (`'Failed to read value: <name>'`). Applications built
  ///   on this binding treat a Bad reading as a failure of the read, which is
  ///   the right call for a screen that would otherwise show a stale number as
  ///   if it were live.
  /// - `true`: the sample is DELIVERED as a value whose
  ///   [DynamicValue.statusCode] is the server's own numeric StatusCode. A
  ///   gateway that maps upstream status onto a published quality needs the
  ///   code, not English: "BadOutOfRange" and "BadCommunicationError" are
  ///   different instructions to an operator, and both are lost in a String.
  ///   Note that such a sample carries no payload — the value is whatever was
  ///   last known — because a Bad DataValue arrives with `hasValue` clear.
  ///
  /// The default stays false so that adding this parameter cannot change what
  /// any existing caller receives.
  Stream<Map<NodeId, DynamicValue>> monitoredItems(
    ReadAttributeParam nodes,
    int subscriptionId, {
    MonitoringMode monitoringMode = MonitoringMode.UA_MONITORINGMODE_REPORTING,
    Duration samplingInterval = const Duration(milliseconds: 100),
    bool discardOldest = true,
    int queueSize = 1,
    bool deliverBadStatus = false,
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
