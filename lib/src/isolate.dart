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

class MonitorMessage extends IsolateMessage {
  final NodeId nodeId;
  final int subscriptionId;
  final MonitoringMode monitoringMode;
  final Duration samplingInterval;
  final bool discardOldest;
  final int queueSize;

  const MonitorMessage(
    super.requestId,
    this.nodeId,
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
  final int resultMask;

  const BrowseMessage(
    String requestId,
    this.nodeId, {
    this.direction = 0,
    this.referenceTypeId,
    this.includeSubtypes = true,
    this.nodeClassMask = 0,
    this.resultMask = BrowseResultMask.all,
  }) : super(requestId);
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
  }) {
    _initIsolate(
      secureChannelLifeTime: secureChannelLifeTime,
      requestedSessionTimeout: requestedSessionTimeout,
      username: username,
      password: password,
      securityMode: securityMode,
      certificate: certificate,
      privateKey: privateKey,
      logLevel: logLevel,
      connectivityCheckInterval: connectivityCheckInterval,
    );
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
    );

    await isolate._initCompleter.future;
    return isolate;
  }

  late final Isolate _isolate;
  late final SendPort _sendPort;
  late final ReceivePort _receivePort;
  final Completer<void> _initCompleter = Completer<void>();

  bool _isClosed = false;
  String? _currentIterateRequestId;

  void _initIsolate({
    Duration? secureChannelLifeTime,
    Duration? requestedSessionTimeout,
    String? username,
    String? password,
    MessageSecurityMode? securityMode,
    Uint8List? certificate,
    Uint8List? privateKey,
    LogLevel? logLevel,
    Duration connectivityCheckInterval = const Duration(seconds: 1),
  }) async {
    try {
      _receivePort = ReceivePort();

      _isolate = await Isolate.spawn(
        _isolateEntryPoint,
        _IsolateData(
          secureChannelLifeTime: secureChannelLifeTime,
          requestedSessionTimeout: requestedSessionTimeout,
          username: username,
          password: password,
          securityMode: securityMode,
          certificate: certificate,
          privateKey: privateKey,
          logLevel: logLevel,
          connectivityCheckInterval: connectivityCheckInterval,
          sendPort: _receivePort.sendPort,
        ),
      );

      _receivePort.listen(_handleMessage);
    } catch (e) {
      _initCompleter.completeError(e);
    }
  }

  void _handleMessage(dynamic message) {
    if (message is SendPort) {
      _sendPort = message;
      _initCompleter.complete();
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
    if (_isClosed) throw const ClientIsolateClosedException();

    final controller = StreamController<DynamicValue>();
    final id = _generateId();
    _streamControllers[id] = controller;

    _sendPort.send(
      MonitorMessage(
        id,
        nodeId,
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
    int resultMask = BrowseResultMask.all,
  }) async {
    if (_isClosed) throw const ClientIsolateClosedException();

    final completer = Completer<List<BrowseResultItem>>();
    final id = _generateId();
    _pendingRequests[id] = completer;

    _sendPort.send(BrowseMessage(
      id,
      nodeId,
      direction: direction,
      referenceTypeId: referenceTypeId,
      includeSubtypes: includeSubtypes,
      nodeClassMask: nodeClassMask,
      resultMask: resultMask,
    ));

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
    Set<NodeClass> recurseInto = const {
      NodeClass.UA_NODECLASS_OBJECT,
      NodeClass.UA_NODECLASS_VIEW,
    },
  }) {
    if (_isClosed) throw const ClientIsolateClosedException();

    final controller = StreamController<BrowseTreeItem>();

    () async {
      final visited = <NodeId>{};

      Future<void> walk(NodeId nodeId, int depth) async {
        if (depth > maxDepth || controller.isClosed) return;
        if (visited.contains(nodeId)) return;
        visited.add(nodeId);

        final children = await browse(
          nodeId,
          referenceTypeId: referenceTypeId,
          includeSubtypes: includeSubtypes,
        );

        for (final child in children) {
          if (controller.isClosed) return;
          controller.add(BrowseTreeItem(
            item: child,
            depth: depth,
            parentNodeId: nodeId,
          ));

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

    _sendPort.send(StateStreamMessage(id));

    controller.onCancel = () {
      _streamControllers.remove(id);
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
    required this.sendPort,
  });
}

/// Entry point for the isolate
void _isolateEntryPoint(_IsolateData data) {
  late Client client;
  Timer? iterateTimer;
  final receivePort = ReceivePort();
  final sendPort = data.sendPort;

  // Track active streams
  final Map<String, StreamSubscription> activeStreams = {};

  // Track endpoint for error messages
  String? endpoint;

  // Flag to prevent runIterate during deletion - Timer.cancel() doesn't
  // wait for in-flight callbacks, so we need this to avoid use-after-free
  bool isDeleting = false;

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
      } else if (message is MonitorMessage) {
        final stream = client.monitor(
          message.nodeId,
          message.subscriptionId,
          monitoringMode: message.monitoringMode,
          samplingInterval: message.samplingInterval,
          discardOldest: message.discardOldest,
          queueSize: message.queueSize,
        );

        // Subscribe to the stream and forward data to main isolate
        final subscription = stream.listen(
          (value) {
            sendPort.send(StreamDataMessage.success(message.requestId, value));
          },
          onError: (error) {
            stderr.writeln("[${endpoint ?? 'unknown'}] Stream error: $error");
            sendPort.send(StreamDataMessage.error(message.requestId, error.toString()));
          },
          onDone: () {
            activeStreams.remove(message.requestId);
          },
        );

        activeStreams[message.requestId] = subscription;

        // Send success response to indicate stream is ready
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

        // Set flag to prevent timer callback from calling runIterate
        isDeleting = true;

        // Cancel the iterate timer
        iterateTimer?.cancel();

        // Yield to allow any already-scheduled timer callback to run and see isDeleting flag
        await Future.delayed(Duration.zero);

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
        iterateTimer?.cancel();
        // Start the iterate timer
        iterateTimer = Timer.periodic(message.timeout, (timer) {
          // Skip if we're in the process of deleting to avoid use-after-free
          if (isDeleting) return;

          if (!client.runIterate(message.timeout)) {
            stderr.writeln("[${endpoint ?? 'unknown'}] runIterate failed, stopping event loop");
            iterateTimer?.cancel();
            sendPort.send(IsolateResponse.error(message.requestId, "Iteration failed"));
          }
        });
      } else if (message is StateStreamMessage) {
        final stream = client.config.stateStream;

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
