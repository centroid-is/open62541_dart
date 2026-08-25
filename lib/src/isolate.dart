import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'client.dart';
import 'client_api.dart';
import 'dynamic_value.dart';
import 'extensions.dart';
import 'node_id.dart';

/// Exception thrown when an operation is attempted on a closed [ClientIsolate].
class ClientIsolateClosedException implements Exception {
  final String message;
  const ClientIsolateClosedException([this.message = 'ClientIsolate is closed']);

  @override
  String toString() => message;
}

/// Thrown into pending requests and monitored-item streams when the client
/// isolate was abandoned and respawned because it stopped answering messages
/// (see [ClientIsolate.keepConnected]'s `unresponsiveTimeout`). Requests
/// should be retried and monitored items resubscribed — the new isolate
/// reconnects on its own.
class ClientIsolateRespawnedException implements Exception {
  final String message;
  const ClientIsolateRespawnedException([
    this.message = 'ClientIsolate was respawned after the isolate became unresponsive',
  ]);

  @override
  String toString() => message;
}

/// Message types for communication between main isolate and client isolate
abstract class IsolateMessage {
  final String requestId;
  const IsolateMessage(this.requestId);
}

class ConnectMessage extends IsolateMessage {
  final String url;
  const ConnectMessage(super.requestId, this.url);
}

class ReadMessage extends IsolateMessage {
  final NodeId nodeId;
  const ReadMessage(super.requestId, this.nodeId);
}

class WriteMessage extends IsolateMessage {
  final NodeId nodeId;
  final DynamicValue value;
  const WriteMessage(super.requestId, this.nodeId, this.value);
}

class ReadAttributeMessage extends IsolateMessage {
  final ReadAttributeParam nodes;
  const ReadAttributeMessage(super.requestId, this.nodes);
}

class SubscriptionCreateMessage extends IsolateMessage {
  final Duration requestedPublishingInterval;
  final int requestedLifetimeCount;
  final int requestedMaxKeepAliveCount;
  final int maxNotificationsPerPublish;
  final bool publishingEnabled;
  final int priority;

  const SubscriptionCreateMessage(
    super.requestId, {
    this.requestedPublishingInterval = const Duration(milliseconds: 100),
    this.requestedLifetimeCount = 10000,
    this.requestedMaxKeepAliveCount = 10,
    this.maxNotificationsPerPublish = 0,
    this.publishingEnabled = true,
    this.priority = 0,
  });
}

class MonitoredItemsMessage extends IsolateMessage {
  final ReadAttributeParam nodes;
  final int subscriptionId;
  final MonitoringMode monitoringMode;
  final Duration samplingInterval;
  final bool discardOldest;
  final int queueSize;

  const MonitoredItemsMessage(
    super.requestId,
    this.nodes,
    this.subscriptionId, {
    this.monitoringMode = MonitoringMode.UA_MONITORINGMODE_REPORTING,
    this.samplingInterval = const Duration(milliseconds: 100),
    this.discardOldest = true,
    this.queueSize = 1,
  });
}

class CallMessage extends IsolateMessage {
  final NodeId objectId;
  final NodeId methodId;
  final List<DynamicValue> args;
  const CallMessage(super.requestId, this.objectId, this.methodId, this.args);
}

class BrowseMessage extends IsolateMessage {
  final NodeId nodeId;
  final int direction;
  final NodeId? referenceTypeId;
  final bool includeSubtypes;
  final int nodeClassMask;
  final BrowseResultMask resultMask;

  const BrowseMessage(
    super.requestId,
    this.nodeId, {
    this.direction = 0,
    this.referenceTypeId,
    this.includeSubtypes = true,
    this.nodeClassMask = 0,
    this.resultMask = BrowseResultMask.UA_BROWSERESULTMASK_ALL,
  });
}

class DisconnectMessage extends IsolateMessage {
  const DisconnectMessage(super.requestId);
}

class DeleteMessage extends IsolateMessage {
  const DeleteMessage(super.requestId);
}

class GetStateMessage extends IsolateMessage {
  const GetStateMessage(super.requestId);
}

class MonitorCancelMessage extends IsolateMessage {
  const MonitorCancelMessage(super.requestId);
}

class AwaitConnectMessage extends IsolateMessage {
  const AwaitConnectMessage(super.requestId);
}

class RunIterateMessage extends IsolateMessage {
  final Duration timeout;
  const RunIterateMessage(super.requestId, this.timeout);
}

class StateStreamMessage extends IsolateMessage {
  const StateStreamMessage(super.requestId);
}

class KeepConnectedMessage extends IsolateMessage {
  final String url;
  final Duration retryInterval;
  final Duration maxBackoff;
  final Duration iterateInterval;
  final Duration handshakeTimeout;
  const KeepConnectedMessage(
    super.requestId,
    this.url, {
    required this.retryInterval,
    required this.maxBackoff,
    required this.iterateInterval,
    required this.handshakeTimeout,
  });
}

class StopKeepConnectedMessage extends IsolateMessage {
  const StopKeepConnectedMessage(super.requestId);
}

class ReconnectStreamMessage extends IsolateMessage {
  const ReconnectStreamMessage(super.requestId);
}

/// Answered immediately by the isolate's message loop; the liveness probe
/// behind [ClientIsolate.keepConnected]'s `unresponsiveTimeout`.
class PingMessage extends IsolateMessage {
  const PingMessage(super.requestId);
}

/// TEST-ONLY: busy-blocks the isolate's event loop for [duration],
/// simulating a native call stuck on a dead socket.
class DebugWedgeMessage extends IsolateMessage {
  final Duration duration;
  const DebugWedgeMessage(super.requestId, this.duration);
}

class StreamDataMessage<T> {
  final String streamId;
  final T? data;
  final String? error;
  final bool isError;

  const StreamDataMessage.success(this.streamId, this.data) : error = null, isError = false;
  const StreamDataMessage.error(this.streamId, this.error) : data = null, isError = true;
}

/// Response wrapper for isolate communication
class IsolateResponse<T> {
  final String requestId;
  final T? data;
  final String? error;
  final bool isError;

  const IsolateResponse.success(this.requestId, this.data) : error = null, isError = false;
  const IsolateResponse.error(this.requestId, this.error) : data = null, isError = true;

  bool get isSuccess => !isError;
}

class ClientIsolate implements ClientApi {
  ClientIsolate._({
    Duration? secureChannelLifeTime,
    Duration? requestedSessionTimeout,
    String? username,
    String? password,
    MessageSecurityMode? securityMode,
    Uint8List? certificate,
    Uint8List? privateKey,
    LogLevel? logLevel,
    Duration connectivityCheckInterval = const Duration(seconds: 1),
    Duration requestTimeout = const Duration(milliseconds: 500),
  }) {
    // Stored as a factory rather than spawned inline so a respawn (see
    // _respawn) can bring up a fresh isolate with the same configuration.
    _isolateDataFactory = (sendPort) => _IsolateData(
      secureChannelLifeTime: secureChannelLifeTime,
      requestedSessionTimeout: requestedSessionTimeout,
      username: username,
      password: password,
      securityMode: securityMode,
      certificate: certificate,
      privateKey: privateKey,
      logLevel: logLevel,
      connectivityCheckInterval: connectivityCheckInterval,
      requestTimeout: requestTimeout,
      sendPort: sendPort,
    );
    _initIsolate();
  }

  /// Factory constructor that creates a ClientIsolate with the specified configuration
  static Future<ClientIsolate> create({
    Duration? secureChannelLifeTime,
    Duration? requestedSessionTimeout,
    String? username,
    String? password,
    MessageSecurityMode? securityMode,
    Uint8List? certificate,
    Uint8List? privateKey,
    LogLevel? logLevel,
    Duration connectivityCheckInterval = const Duration(seconds: 1),
    Duration iterateInterval = const Duration(milliseconds: 10),
    Duration requestTimeout = const Duration(milliseconds: 500),
  }) async {
    final isolate = ClientIsolate._(
      secureChannelLifeTime: secureChannelLifeTime,
      requestedSessionTimeout: requestedSessionTimeout,
      username: username,
      password: password,
      securityMode: securityMode,
      certificate: certificate,
      privateKey: privateKey,
      logLevel: logLevel,
      connectivityCheckInterval: connectivityCheckInterval,
      requestTimeout: requestTimeout,
    );

    await isolate._initCompleter.future;
    return isolate;
  }

  // Reassignable (not `late final`): _respawn abandons the wedged isolate
  // and installs a fresh one behind the same ClientIsolate object.
  late Isolate _isolate;
  late SendPort _sendPort;
  late ReceivePort _receivePort;
  Completer<void> _initCompleter = Completer<void>();
  late final _IsolateData Function(SendPort sendPort) _isolateDataFactory;

  bool _isClosed = false;
  String? _currentIterateRequestId;

  // keepConnected supervisor state on the MAIN side. The in-isolate
  // supervisor handles everything open62541 reports; this side only has to
  // handle the isolate itself going silent (wedged in a native call).
  String? _keepConnectedUrl;
  Duration _kcRetryInterval = const Duration(milliseconds: 500);
  Duration _kcMaxBackoff = const Duration(seconds: 5);
  Duration _kcIterateInterval = const Duration(milliseconds: 10);
  Duration _kcHandshakeTimeout = const Duration(seconds: 10);
  Duration? _unresponsiveTimeout;
  bool _pingLoopRunning = false;
  bool _respawning = false;

  // Stream ids that must survive a respawn as OBJECTS: callers subscribe to
  // stateStream/reconnectStream once at construction and never again, so the
  // same controllers are re-armed on the new isolate instead of being closed.
  final Set<String> _stateStreamIds = {};
  final Set<String> _reconnectStreamIds = {};

  // Cancellable sleeps for the ping loop; delete()/stopKeepConnected wake
  // them so no timer outlives the client (widget-test teardown asserts on
  // pending timers).
  final Map<Timer, Completer<void>> _supervisorSleeps = {};

  void _initIsolate() async {
    try {
      _receivePort = ReceivePort();

      _isolate = await Isolate.spawn(_isolateEntryPoint, _isolateDataFactory(_receivePort.sendPort));

      _receivePort.listen(_handleMessage);
    } catch (e) {
      if (!_initCompleter.isCompleted) _initCompleter.completeError(e);
    }
  }

  void _handleMessage(dynamic message) {
    if (message is SendPort) {
      _sendPort = message;
      if (!_initCompleter.isCompleted) _initCompleter.complete();
    } else if (message is IsolateResponse) {
      final completer = _pendingRequests[message.requestId];
      if (completer != null) {
        if (message.isError) {
          completer.completeError(message.error!);
        } else {
          completer.complete(message.data);
        }
      }
    } else if (message is StreamDataMessage) {
      final controller = _streamControllers[message.streamId];
      if (controller != null) {
        if (message.isError) {
          controller.addError(message.error!);
        } else {
          controller.add(message.data);
        }
      }
    }
  }

  /// Connect to an OPC UA server
  @override
  Future<void> connect(String url) async {
    if (_isClosed) throw const ClientIsolateClosedException();

    final completer = Completer<void>();
    final id = _generateId();
    _pendingRequests[id] = completer;

    _sendPort.send(ConnectMessage(id, url));

    try {
      await completer.future;
    } finally {
      _pendingRequests.remove(id);
    }
  }

  /// Read a value from the server
  @override
  Future<DynamicValue> read(NodeId nodeId) async {
    if (_isClosed) throw const ClientIsolateClosedException();

    final completer = Completer<DynamicValue>();
    final id = _generateId();
    _pendingRequests[id] = completer;

    _sendPort.send(ReadMessage(id, nodeId));

    try {
      return await completer.future;
    } finally {
      _pendingRequests.remove(id);
    }
  }

  /// Write a value to the server
  @override
  Future<void> write(NodeId nodeId, DynamicValue value) async {
    if (_isClosed) throw const ClientIsolateClosedException();

    final completer = Completer<void>();
    final id = _generateId();
    _pendingRequests[id] = completer;

    _sendPort.send(WriteMessage(id, nodeId, value));

    try {
      await completer.future;
    } finally {
      _pendingRequests.remove(id);
    }
  }

  /// Read multiple attributes
  @override
  Future<Map<NodeId, DynamicValue>> readAttribute(ReadAttributeParam nodes) async {
    if (_isClosed) throw const ClientIsolateClosedException();

    final completer = Completer<Map<NodeId, DynamicValue>>();
    final id = _generateId();
    _pendingRequests[id] = completer;

    _sendPort.send(ReadAttributeMessage(id, nodes));

    try {
      return await completer.future;
    } finally {
      _pendingRequests.remove(id);
    }
  }

  /// Create a subscription
  @override
  Future<int> subscriptionCreate({
    Duration requestedPublishingInterval = const Duration(milliseconds: 100),
    int requestedLifetimeCount = 10000,
    int requestedMaxKeepAliveCount = 10,
    int maxNotificationsPerPublish = 0,
    bool publishingEnabled = true,
    int priority = 0,
  }) async {
    if (_isClosed) throw const ClientIsolateClosedException();

    final completer = Completer<int>();
    final id = _generateId();
    _pendingRequests[id] = completer;

    _sendPort.send(
      SubscriptionCreateMessage(
        id,
        requestedPublishingInterval: requestedPublishingInterval,
        requestedLifetimeCount: requestedLifetimeCount,
        requestedMaxKeepAliveCount: requestedMaxKeepAliveCount,
        maxNotificationsPerPublish: maxNotificationsPerPublish,
        publishingEnabled: publishingEnabled,
        priority: priority,
      ),
    );

    try {
      return await completer.future;
    } finally {
      _pendingRequests.remove(id);
    }
  }

  /// Monitor a node
  @override
  Stream<DynamicValue> monitor(
    NodeId nodeId,
    int subscriptionId, {
    MonitoringMode monitoringMode = MonitoringMode.UA_MONITORINGMODE_REPORTING,
    Duration samplingInterval = const Duration(milliseconds: 100),
    bool discardOldest = true,
    int queueSize = 1,
  }) {
    final controller = StreamController<DynamicValue>();
    final stream = monitoredItems(
      {
        nodeId: [
          AttributeId.UA_ATTRIBUTEID_DATATYPE,
          AttributeId.UA_ATTRIBUTEID_VALUE,
          AttributeId.UA_ATTRIBUTEID_DESCRIPTION,
          AttributeId.UA_ATTRIBUTEID_DISPLAYNAME,
        ],
      },
      subscriptionId,
      monitoringMode: monitoringMode,
      samplingInterval: samplingInterval,
      discardOldest: discardOldest,
      queueSize: queueSize,
    );
    final subscription = stream.listen((event) => controller.add(event.values.first));
    subscription.onError((error) => controller.addError(error));
    controller.onCancel = () {
      subscription.cancel();
    };
    subscription.onDone(() {
      controller.close();
    });
    return controller.stream;
  }

  /// Monitor multiple nodes and attributes
  @override
  Stream<Map<NodeId, DynamicValue>> monitoredItems(
    ReadAttributeParam nodes,
    int subscriptionId, {
    MonitoringMode monitoringMode = MonitoringMode.UA_MONITORINGMODE_REPORTING,
    Duration samplingInterval = const Duration(milliseconds: 100),
    bool discardOldest = true,
    int queueSize = 1,
  }) {
    if (_isClosed) throw const ClientIsolateClosedException();

    final controller = StreamController<Map<NodeId, DynamicValue>>();
    final id = _generateId();
    _streamControllers[id] = controller;

    _sendPort.send(
      MonitoredItemsMessage(
        id,
        nodes,
        subscriptionId,
        monitoringMode: monitoringMode,
        samplingInterval: samplingInterval,
        discardOldest: discardOldest,
        queueSize: queueSize,
      ),
    );

    controller.onCancel = () {
      _streamControllers.remove(id);
      if (!_isClosed) {
        _sendPort.send(MonitorCancelMessage(id));
      }
    };

    return controller.stream;
  }

  /// Call a method
  @override
  Future<List<DynamicValue>> call(NodeId objectId, NodeId methodId, Iterable<DynamicValue> args) async {
    if (_isClosed) throw const ClientIsolateClosedException();

    final completer = Completer<List<DynamicValue>>();
    final id = _generateId();
    _pendingRequests[id] = completer;

    _sendPort.send(CallMessage(id, objectId, methodId, args.toList()));

    try {
      return await completer.future;
    } finally {
      _pendingRequests.remove(id);
    }
  }

  /// Browse a node
  @override
  Future<List<BrowseResultItem>> browse(
    NodeId nodeId, {
    int direction = 0,
    NodeId? referenceTypeId,
    bool includeSubtypes = true,
    int nodeClassMask = 0,
    BrowseResultMask resultMask = BrowseResultMask.UA_BROWSERESULTMASK_ALL,
  }) async {
    if (_isClosed) throw const ClientIsolateClosedException();

    final completer = Completer<List<BrowseResultItem>>();
    final id = _generateId();
    _pendingRequests[id] = completer;

    _sendPort.send(
      BrowseMessage(
        id,
        nodeId,
        direction: direction,
        referenceTypeId: referenceTypeId,
        includeSubtypes: includeSubtypes,
        nodeClassMask: nodeClassMask,
        resultMask: resultMask,
      ),
    );

    try {
      return await completer.future;
    } finally {
      _pendingRequests.remove(id);
    }
  }

  /// Recursively browse the address space tree
  @override
  Stream<BrowseTreeItem> browseTree(
    NodeId root, {
    int maxDepth = 100,
    NodeId? referenceTypeId,
    bool includeSubtypes = true,
    Set<NodeClass> recurseInto = const {NodeClass.UA_NODECLASS_OBJECT, NodeClass.UA_NODECLASS_VIEW},
  }) {
    if (_isClosed) throw const ClientIsolateClosedException();

    final controller = StreamController<BrowseTreeItem>();

    () async {
      final visited = <NodeId>{};

      Future<void> walk(NodeId nodeId, int depth) async {
        if (depth > maxDepth || controller.isClosed) return;
        if (visited.contains(nodeId)) return;
        visited.add(nodeId);

        final children = await browse(nodeId, referenceTypeId: referenceTypeId, includeSubtypes: includeSubtypes);

        for (final child in children) {
          if (controller.isClosed) return;
          controller.add(BrowseTreeItem(item: child, depth: depth, parentNodeId: nodeId));

          if (recurseInto.contains(child.nodeClass)) {
            await walk(child.nodeId, depth + 1);
          }
        }
      }

      try {
        await walk(root, 0);
      } catch (e) {
        controller.addError(e);
      } finally {
        controller.close();
      }
    }();

    return controller.stream;
  }

  /// Get the current client state
  Future<ClientState> get state async {
    if (_isClosed) throw const ClientIsolateClosedException();

    final completer = Completer<ClientState>();
    final id = _generateId();
    _pendingRequests[id] = completer;

    _sendPort.send(GetStateMessage(id));

    try {
      return await completer.future;
    } finally {
      _pendingRequests.remove(id);
    }
  }

  /// Get a stream of client state changes
  @override
  Stream<ClientState> get stateStream {
    if (_isClosed) throw const ClientIsolateClosedException();

    final controller = StreamController<ClientState>();
    final id = _generateId();
    _streamControllers[id] = controller;
    // Survives a respawn as an object: callers subscribe once at
    // construction and never again, so _respawn re-arms this id on the new
    // isolate and the same stream keeps emitting.
    _stateStreamIds.add(id);

    _sendPort.send(StateStreamMessage(id));

    controller.onCancel = () {
      _streamControllers.remove(id);
      _stateStreamIds.remove(id);
      if (!_isClosed) {
        _sendPort.send(MonitorCancelMessage(id));
      }
    };

    return controller.stream;
  }

  /// Opt-in auto-reconnect, mirroring [Client.keepConnected] for the isolate
  /// client. The supervisor (and its run_iterate pump) runs INSIDE the
  /// isolate, so recovery works even when the session dies without native
  /// runIterate ever returning an error — the failure mode where a
  /// caller-driven [runIterate] loop parks forever.
  ///
  /// The returned future completes when the session first reaches ACTIVATED.
  /// After that the supervisor keeps running until [stopKeepConnected] (or
  /// [delete]) is called. This method OWNS the event-loop pump: do not run
  /// [runIterate] alongside it — any caller-started iterate loop is stopped
  /// when the supervisor starts.
  ///
  /// Listen to [reconnectStream] to re-create subscriptions after each
  /// recovered drop (open62541 clears client-side subscriptions on a drop).
  /// See [Client.keepConnected]. With [unresponsiveTimeout] set, this side
  /// additionally supervises the ISOLATE itself: it pings the isolate's
  /// message loop, and when the isolate stops answering — observed in
  /// production when a dead secured connection wedges a native call, at
  /// which point nothing sent through the isolate (not even disconnect) is
  /// ever processed — the isolate is abandoned and respawned:
  ///
  ///  * pending requests complete with [ClientIsolateRespawnedException]
  ///    (retry them);
  ///  * monitored-item streams get that error and close (their native
  ///    subscriptions died with the old isolate — resubscribe);
  ///  * [stateStream]/[reconnectStream] objects SURVIVE and keep emitting
  ///    from the new isolate;
  ///  * the supervisor re-arms itself, so the session reconnects with no
  ///    action from the caller.
  Future<void> keepConnected(
    String url, {
    Duration retryInterval = const Duration(milliseconds: 500),
    Duration maxBackoff = const Duration(seconds: 5),
    Duration iterateInterval = const Duration(milliseconds: 10),
    Duration handshakeTimeout = const Duration(seconds: 10),
    Duration? unresponsiveTimeout,
  }) async {
    if (_isClosed) throw const ClientIsolateClosedException();

    _keepConnectedUrl = url;
    _kcRetryInterval = retryInterval;
    _kcMaxBackoff = maxBackoff;
    _kcIterateInterval = iterateInterval;
    _kcHandshakeTimeout = handshakeTimeout;
    _unresponsiveTimeout = unresponsiveTimeout;

    final completer = Completer<void>();
    final id = _generateId();
    _pendingRequests[id] = completer;

    _sendPort.send(
      KeepConnectedMessage(
        id,
        url,
        retryInterval: retryInterval,
        maxBackoff: maxBackoff,
        iterateInterval: iterateInterval,
        handshakeTimeout: handshakeTimeout,
      ),
    );

    if (unresponsiveTimeout != null) {
      _startPingLoop();
    }

    try {
      await completer.future;
    } finally {
      _pendingRequests.remove(id);
    }
  }

  /// Sleep that [delete]/[stopKeepConnected] can wake, so no timer outlives
  /// the client.
  Future<void> _sleep(Duration d) {
    final c = Completer<void>();
    late final Timer t;
    t = Timer(d, () {
      _supervisorSleeps.remove(t);
      if (!c.isCompleted) c.complete();
    });
    _supervisorSleeps[t] = c;
    return c.future;
  }

  void _wakeSleeps() {
    for (final entry in _supervisorSleeps.entries.toList()) {
      entry.key.cancel();
      if (!entry.value.isCompleted) entry.value.complete();
    }
    _supervisorSleeps.clear();
  }

  /// One liveness probe: true if the isolate answered within [timeout].
  Future<bool> _ping(Duration timeout) async {
    final completer = Completer<void>();
    final id = _generateId();
    _pendingRequests[id] = completer;
    var answered = false;
    final settled = completer.future.then((_) {
      answered = true;
    }, onError: (_) {});
    try {
      _sendPort.send(PingMessage(id));
    } catch (_) {}
    await Future.any([settled, _sleep(timeout)]);
    _pendingRequests.remove(id);
    return answered;
  }

  void _startPingLoop() {
    if (_pingLoopRunning) return;
    _pingLoopRunning = true;
    () async {
      var missed = 0;
      // Respawn backoff: a genuinely dead endpoint must be respawned gently,
      // not hammered — every respawn abandons a native client (thread +
      // socket until the wedged call returns), so a tight loop would itself
      // leak resources. Doubles per respawn, resets on any answered ping.
      var respawnBackoff = _unresponsiveTimeout ?? const Duration(seconds: 15);
      while (!_isClosed && _keepConnectedUrl != null && _unresponsiveTimeout != null) {
        // Three probes per timeout window: ~3 consecutive misses means the
        // isolate has been silent for about unresponsiveTimeout.
        final interval = _unresponsiveTimeout! ~/ 3;
        await _sleep(interval);
        if (_isClosed || _keepConnectedUrl == null) break;
        if (_respawning) {
          missed = 0;
          continue;
        }
        final ok = await _ping(interval);
        if (ok) {
          missed = 0;
          respawnBackoff = _unresponsiveTimeout!;
          continue;
        }
        missed++;
        if (missed >= 3) {
          missed = 0;
          try {
            await _respawn();
          } catch (_) {
            // Spawn failed; the loop keeps probing and will try again.
          }
          await _sleep(respawnBackoff);
          respawnBackoff *= 2;
          const maxRespawnBackoff = Duration(minutes: 1);
          if (respawnBackoff > maxRespawnBackoff) respawnBackoff = maxRespawnBackoff;
        }
      }
      _pingLoopRunning = false;
    }();
  }

  /// Abandon the (presumed wedged) isolate and bring up a fresh one behind
  /// this same object. Killing is BEST EFFORT: an isolate blocked inside a
  /// native call only dies when that call returns — do not wait for it;
  /// leaking one thread beats a frozen client.
  Future<void> _respawn() async {
    if (_isClosed || _respawning) return;
    _respawning = true;
    try {
      stderr.writeln('[${_keepConnectedUrl ?? 'unknown'}] isolate unresponsive — abandoning it and respawning');
      try {
        _receivePort.close();
      } catch (_) {}
      try {
        _isolate.kill(priority: Isolate.immediate);
      } catch (_) {}

      // Every pending request belonged to the dead isolate.
      final pending = Map<String, Completer>.from(_pendingRequests);
      _pendingRequests.clear();
      for (final c in pending.values) {
        if (!c.isCompleted) c.completeError(const ClientIsolateRespawnedException());
      }
      _currentIterateRequestId = null;

      // Monitored-item streams: their native subscriptions died with the old
      // isolate. Error + close so callers resubscribe. State/reconnect
      // streams survive as objects and are re-armed below.
      final surviving = {..._stateStreamIds, ..._reconnectStreamIds};
      final doomed = <String, StreamController>{};
      _streamControllers.forEach((id, controller) {
        if (!surviving.contains(id)) doomed[id] = controller;
      });
      for (final entry in doomed.entries) {
        _streamControllers.remove(entry.key);
        if (!entry.value.isClosed) {
          entry.value.addError(const ClientIsolateRespawnedException());
          entry.value.close();
        }
      }

      // Fresh isolate from the stored spawn parameters. Bounded: a hung
      // spawn must not park the ping loop forever — on timeout we bail and
      // the loop's next round retries the respawn.
      _initCompleter = Completer<void>();
      _initIsolate();
      var initDone = false;
      final initSettled = _initCompleter.future.then((_) {
        initDone = true;
      }, onError: (_) {});
      await Future.any([initSettled, _sleep(const Duration(seconds: 10))]);
      if (!initDone) return;

      // Surviving streams keep emitting from the new isolate.
      for (final id in _stateStreamIds) {
        if (_streamControllers.containsKey(id)) {
          _sendPort.send(StateStreamMessage(id));
        }
      }
      for (final id in _reconnectStreamIds) {
        if (_streamControllers.containsKey(id)) {
          _sendPort.send(ReconnectStreamMessage(id));
        }
      }

      // Re-arm the supervisor; the session then reconnects on its own. The
      // response to this message is deliberately unregistered — first
      // activation was already reported to the original caller.
      final url = _keepConnectedUrl;
      if (url != null) {
        _sendPort.send(
          KeepConnectedMessage(
            _generateId(),
            url,
            retryInterval: _kcRetryInterval,
            maxBackoff: _kcMaxBackoff,
            iterateInterval: _kcIterateInterval,
            handshakeTimeout: _kcHandshakeTimeout,
          ),
        );
      }
    } finally {
      _respawning = false;
    }
  }

  /// TEST-ONLY: busy-blocks the isolate's event loop for [duration],
  /// simulating a native call stuck on a dead socket. Unlike the real FFI
  /// wedge the busy-wait is killable, so respawn tests can clean up.
  void debugWedgeIsolate(Duration duration) {
    if (_isClosed) throw const ClientIsolateClosedException();
    _sendPort.send(DebugWedgeMessage(_generateId(), duration));
  }

  /// Stops the auto-reconnect supervisor started by [keepConnected]. Does not
  /// disconnect an established session; call [disconnect] / [delete]
  /// separately if desired.
  Future<void> stopKeepConnected() async {
    if (_isClosed) throw const ClientIsolateClosedException();

    // Stop the main-side liveness supervisor too, waking any sleep so no
    // timer outlives the caller's interest.
    _keepConnectedUrl = null;
    _unresponsiveTimeout = null;
    _wakeSleeps();

    final completer = Completer<void>();
    final id = _generateId();
    _pendingRequests[id] = completer;

    _sendPort.send(StopKeepConnectedMessage(id));

    try {
      await completer.future;
    } finally {
      _pendingRequests.remove(id);
    }
  }

  /// Fires once each time the session returns to ACTIVATED after a recovered
  /// drop (see [Client.reconnectStream]). Only emits while [keepConnected]
  /// is supervising. Does not fire for the very first connect.
  Stream<void> get reconnectStream {
    if (_isClosed) throw const ClientIsolateClosedException();

    final controller = StreamController<void>();
    final id = _generateId();
    _streamControllers[id] = controller;
    // Survives a respawn as an object: re-armed on the new isolate.
    _reconnectStreamIds.add(id);

    _sendPort.send(ReconnectStreamMessage(id));

    controller.onCancel = () {
      _streamControllers.remove(id);
      _reconnectStreamIds.remove(id);
      if (!_isClosed) {
        _sendPort.send(MonitorCancelMessage(id));
      }
    };

    return controller.stream;
  }

  /// Disconnect from the server
  Future<void> disconnect() async {
    if (_isClosed) throw const ClientIsolateClosedException();

    final completer = Completer<void>();
    final id = _generateId();
    _pendingRequests[id] = completer;

    _sendPort.send(DisconnectMessage(id));

    try {
      await completer.future;
    } finally {
      _pendingRequests.remove(id);
    }
  }

  /// Delete the isolate and clean up resources
  @override
  Future<void> delete() async {
    if (_isClosed) return;
    _isClosed = true;

    // Stop the liveness supervisor and wake its sleeps so no timer outlives
    // the client.
    _keepConnectedUrl = null;
    _unresponsiveTimeout = null;
    _wakeSleeps();

    // Cancel all pending requests with an error before cleanup
    final pendingToCancel = Map<String, Completer>.from(_pendingRequests);
    for (final entry in pendingToCancel.entries) {
      if (!entry.value.isCompleted) {
        entry.value.completeError(const ClientIsolateClosedException());
      }
    }
    _pendingRequests.clear();

    // Close all stream controllers
    for (final controller in _streamControllers.values) {
      controller.close();
    }
    _streamControllers.clear();

    // Send delete message to isolate
    final completer = Completer<void>();
    final id = _generateId();
    _pendingRequests[id] = completer;

    _sendPort.send(DeleteMessage(id));

    try {
      await completer.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          // If isolate doesn't respond, continue with cleanup
        },
      );
    } finally {
      _pendingRequests.remove(id);
    }

    _isolate.kill();
    _receivePort.close();
  }

  /// Wait for the connection to be fully established
  @override
  Future<void> awaitConnect() async {
    if (_isClosed) throw const ClientIsolateClosedException();

    final completer = Completer<void>();
    final id = _generateId();
    _pendingRequests[id] = completer;

    _sendPort.send(AwaitConnectMessage(id));

    try {
      await completer.future;
    } finally {
      _pendingRequests.remove(id);
    }
  }

  /// Run iterate in a loop
  /// The duration is the time for each iteration
  /// Never returns, unless there was an error
  Future<void> runIterate({Duration duration = const Duration(milliseconds: 10)}) async {
    if (_isClosed) throw const ClientIsolateClosedException();

    // Cancel previous iterate request if any
    if (_currentIterateRequestId != null) {
      final oldCompleter = _pendingRequests.remove(_currentIterateRequestId);
      if (oldCompleter != null && !oldCompleter.isCompleted) {
        oldCompleter.completeError(StateError('Replaced by new runIterate call'));
      }
    }

    final completer = Completer<void>();
    final id = _generateId();
    _currentIterateRequestId = id;
    _pendingRequests[id] = completer;

    _sendPort.send(RunIterateMessage(id, duration));

    try {
      await completer.future;
    } finally {
      _pendingRequests.remove(id);
      if (_currentIterateRequestId == id) {
        _currentIterateRequestId = null;
      }
    }
  }

  // Private fields for request tracking
  final Map<String, Completer> _pendingRequests = {};
  final Map<String, StreamController> _streamControllers = {};
  int _requestIdCounter = 0;

  String _generateId() {
    return 'req_${_requestIdCounter++}';
  }
}

/// Data structure passed to the isolate
class _IsolateData {
  final Duration? secureChannelLifeTime;
  final Duration? requestedSessionTimeout;
  final String? username;
  final String? password;
  final MessageSecurityMode? securityMode;
  final Uint8List? certificate;
  final Uint8List? privateKey;
  final LogLevel? logLevel;
  final Duration connectivityCheckInterval;
  final Duration requestTimeout;
  final SendPort sendPort;

  _IsolateData({
    this.secureChannelLifeTime,
    this.requestedSessionTimeout,
    this.username,
    this.password,
    this.securityMode,
    this.certificate,
    this.privateKey,
    this.logLevel,
    required this.connectivityCheckInterval,
    required this.requestTimeout,
    required this.sendPort,
  });
}

/// Entry point for the isolate
void _isolateEntryPoint(_IsolateData data) {
  late Client client;
  final receivePort = ReceivePort();
  final sendPort = data.sendPort;

  // Track active streams
  final Map<String, StreamSubscription> activeStreams = {};

  // Track endpoint for error messages
  String? endpoint;

  // Iterate loop control — uses an async loop instead of Timer.periodic
  // so deletion can await full termination (no race condition).
  bool iterateRunning = false;
  Completer<void>? iterateStopped;

  // Send our receive port back to the main isolate
  sendPort.send(receivePort.sendPort);

  client = Client(
    secureChannelLifeTime: data.secureChannelLifeTime,
    requestedSessionTimeout: data.requestedSessionTimeout,
    username: data.username,
    password: data.password,
    securityMode: data.securityMode,
    certificate: data.certificate,
    privateKey: data.privateKey,
    logLevel: data.logLevel,
    connectivityCheckInterval: data.connectivityCheckInterval,
    requestTimeout: data.requestTimeout,
  );

  // Handle messages from the main isolate
  receivePort.listen((message) async {
    try {
      if (message is ConnectMessage) {
        endpoint = message.url;
        await client.connect(message.url);
        sendPort.send(IsolateResponse.success(message.requestId, null));
      } else if (message is ReadMessage) {
        final result = await client.read(message.nodeId);
        sendPort.send(IsolateResponse.success(message.requestId, result));
      } else if (message is WriteMessage) {
        await client.write(message.nodeId, message.value);
        sendPort.send(IsolateResponse.success(message.requestId, null));
      } else if (message is ReadAttributeMessage) {
        final result = await client.readAttribute(message.nodes);
        sendPort.send(IsolateResponse.success(message.requestId, result));
      } else if (message is SubscriptionCreateMessage) {
        final result = await client.subscriptionCreate(
          requestedPublishingInterval: message.requestedPublishingInterval,
          requestedLifetimeCount: message.requestedLifetimeCount,
          requestedMaxKeepAliveCount: message.requestedMaxKeepAliveCount,
          maxNotificationsPerPublish: message.maxNotificationsPerPublish,
          publishingEnabled: message.publishingEnabled,
          priority: message.priority,
        );
        sendPort.send(IsolateResponse.success(message.requestId, result));
      } else if (message is MonitoredItemsMessage) {
        final stream = client.monitoredItems(
          message.nodes,
          message.subscriptionId,
          monitoringMode: message.monitoringMode,
          samplingInterval: message.samplingInterval,
          discardOldest: message.discardOldest,
          queueSize: message.queueSize,
        );

        final subscription = stream.listen(
          (value) {
            sendPort.send(StreamDataMessage.success(message.requestId, value));
          },
          onError: (error) {
            stderr.writeln("[${endpoint ?? 'unknown'}] MonitoredItems stream error: $error");
            sendPort.send(StreamDataMessage.error(message.requestId, error.toString()));
          },
          onDone: () {
            activeStreams.remove(message.requestId);
          },
        );

        activeStreams[message.requestId] = subscription;

        sendPort.send(IsolateResponse.success(message.requestId, null));
      } else if (message is MonitorCancelMessage) {
        // Cancel the stream
        final subscription = activeStreams[message.requestId];
        if (subscription != null) {
          await subscription.cancel();
          activeStreams.remove(message.requestId);
        }
        sendPort.send(IsolateResponse.success(message.requestId, null));
      } else if (message is CallMessage) {
        final result = await client.call(message.objectId, message.methodId, message.args);
        sendPort.send(IsolateResponse.success(message.requestId, result));
      } else if (message is BrowseMessage) {
        final result = await client.browse(
          message.nodeId,
          direction: message.direction,
          referenceTypeId: message.referenceTypeId,
          includeSubtypes: message.includeSubtypes,
          nodeClassMask: message.nodeClassMask,
          resultMask: message.resultMask,
        );
        sendPort.send(IsolateResponse.success(message.requestId, result));
      } else if (message is GetStateMessage) {
        final result = client.state;
        sendPort.send(IsolateResponse.success(message.requestId, result));
      } else if (message is DisconnectMessage) {
        client.disconnect();
        sendPort.send(IsolateResponse.success(message.requestId, null));
      } else if (message is DeleteMessage) {
        stderr.writeln("[${endpoint ?? 'unknown'}] Shutting down isolate (${activeStreams.length} active streams)");

        // Stop the iterate loop and wait for it to fully drain
        iterateRunning = false;
        if (iterateStopped != null) {
          await iterateStopped!.future;
        }

        // Cancel all active streams
        for (final subscription in activeStreams.values) {
          await subscription.cancel();
        }
        activeStreams.clear();

        await client.delete();
        sendPort.send(IsolateResponse.success(message.requestId, null));
      } else if (message is AwaitConnectMessage) {
        await client.awaitConnect();
        sendPort.send(IsolateResponse.success(message.requestId, null));
      } else if (message is RunIterateMessage) {
        // Stop any previous iterate loop
        iterateRunning = false;
        if (iterateStopped != null) {
          await iterateStopped!.future;
        }

        // Start a new async iterate loop — the `iterateRunning` flag and
        // `iterateStopped` completer let the delete handler await full
        // termination, eliminating the Timer.periodic race condition.
        iterateRunning = true;
        final stopped = Completer<void>();
        iterateStopped = stopped;

        () async {
          while (iterateRunning) {
            if (!client.runIterate(message.timeout)) {
              stderr.writeln("[${endpoint ?? 'unknown'}] runIterate failed, stopping event loop");
              sendPort.send(IsolateResponse.error(message.requestId, "Iteration failed"));
              break;
            }
            await Future.delayed(message.timeout);
          }
          stopped.complete();
        }();
      } else if (message is PingMessage) {
        // Liveness probe: answered immediately. If this stops being
        // answered, the isolate is wedged (typically a native call stuck on
        // a dead socket) and the main side respawns it.
        sendPort.send(IsolateResponse.success(message.requestId, null));
      } else if (message is DebugWedgeMessage) {
        // TEST-ONLY: synchronous busy-wait — blocks this isolate's event
        // loop entirely, like a native call stuck on a dead socket.
        final end = DateTime.now().add(message.duration);
        while (DateTime.now().isBefore(end)) {}
        sendPort.send(IsolateResponse.success(message.requestId, null));
      } else if (message is KeepConnectedMessage) {
        // The supervisor owns the run_iterate pump — stop any caller-driven
        // iterate loop first so the client is not pumped twice.
        iterateRunning = false;
        if (iterateStopped != null) {
          await iterateStopped!.future;
        }
        endpoint = message.url;
        // Respond on first activation; the supervisor keeps running inside
        // this isolate afterwards, reconnecting across drops on its own.
        unawaited(
          client
              .keepConnected(
                message.url,
                retryInterval: message.retryInterval,
                maxBackoff: message.maxBackoff,
                iterateInterval: message.iterateInterval,
              )
              .then((_) => sendPort.send(IsolateResponse.success(message.requestId, null)))
              .catchError((Object e) => sendPort.send(IsolateResponse.error(message.requestId, e.toString()))),
        );
      } else if (message is StopKeepConnectedMessage) {
        client.stopKeepConnected();
        sendPort.send(IsolateResponse.success(message.requestId, null));
      } else if (message is ReconnectStreamMessage) {
        final subscription = client.reconnectStream.listen(
          (_) {
            sendPort.send(StreamDataMessage<void>.success(message.requestId, null));
          },
          onError: (error) {
            sendPort.send(StreamDataMessage<void>.error(message.requestId, error.toString()));
          },
          onDone: () {
            activeStreams.remove(message.requestId);
          },
        );

        activeStreams[message.requestId] = subscription;

        // Send success response to indicate stream is ready
        sendPort.send(IsolateResponse.success(message.requestId, null));
      } else if (message is StateStreamMessage) {
        // The client-lifetime forwarder, not config.stateStream: it keeps
        // emitting across native-client recreations inside keepConnected.
        final stream = client.stateStream;

        final subscription = stream.listen(
          (state) {
            sendPort.send(StreamDataMessage.success(message.requestId, state));
          },
          onError: (error) {
            stderr.writeln("[${endpoint ?? 'unknown'}] State stream error: $error");
            sendPort.send(StreamDataMessage.error(message.requestId, error.toString()));
          },
          onDone: () {
            activeStreams.remove(message.requestId);
          },
        );

        activeStreams[message.requestId] = subscription;

        // Send success response to indicate stream is ready
        sendPort.send(IsolateResponse.success(message.requestId, null));
      }
    } catch (e) {
      stderr.writeln("[${endpoint ?? 'unknown'}] Error in isolate: $e");
      if (message is IsolateMessage) {
        sendPort.send(IsolateResponse.error(message.requestId, e.toString()));
      }
    }
  });
}
