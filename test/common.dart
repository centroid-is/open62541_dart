import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';

/// Returns a TCP port that is free right now, allocated by the OS.
///
/// `dart test` runs suite files in PARALLEL, so tests that picked ports with
/// `Random().nextInt(10000) + 4840` could collide across concurrently running
/// suites: two servers racing to bind the same port, or worse, a client
/// connecting to another suite's server that then tears down mid-session
/// (broken pipe -> service faults with zero results). Binding port 0 lets the
/// OS hand out a port from its ephemeral range, which both avoids
/// suite-vs-suite collisions and stays clear of 4840-14839, where local
/// Docker rigs commonly publish OPC UA ports.
///
/// The tiny window between closing the probe socket and the server binding
/// the port is safe in practice: the OS does not reuse an ephemeral port it
/// just handed out while other ports remain available.
Future<int> freeTcpPort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

/// Holds [port] until the end of the current test so that nothing else can
/// bind it.
///
/// **Why a test that kills its server has to do this.** `dart test` runs suites
/// in parallel and [freeTcpPort] hands out a port by binding :0 and letting
/// it go, so a port a suite releases can be handed straight to another
/// suite's server. A client that is still alive and still reconnecting at
/// the address it was given would connect into that server and open a
/// session there, and the suite that owns it would see a session it never
/// created. `server_statistics_test` asserts exact session counts and is the
/// one that catches it, from the other side, as a timeout on
/// `currentSessionCount == 1` with an extra session in the snapshot.
///
/// Accepted connections are destroyed at once: the point is only to keep the
/// port occupied, and a socket that accepts and says nothing leaves the
/// client's channel exactly as dead as a closed port does.
Future<ServerSocket> holdPort(int port) async {
  final held = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
  held.listen((socket) => socket.destroy());
  addTearDown(() => held.close());
  return held;
}

/// A TCP proxy in front of [targetPort], so a test can cut a client's
/// connection, and with it the secure channel, without stopping the server.
/// The server then keeps the session and its monitored items, and the client
/// re-activates that session once the proxy is back ([resume]).
class TcpProxy {
  TcpProxy._(this.port, this.targetPort);

  /// The port clients connect to.
  final int port;
  final int targetPort;
  ServerSocket? _listener;
  final List<Socket> _sockets = [];

  static Future<TcpProxy> start(int targetPort) async {
    final proxy = TcpProxy._(await freeTcpPort(), targetPort);
    await proxy.resume();
    addTearDown(proxy.cut);
    return proxy;
  }

  /// Accepts connections (again) and forwards them to [targetPort].
  Future<void> resume() async {
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    _listener = listener;
    listener.listen((client) async {
      try {
        final upstream = await Socket.connect(InternetAddress.loopbackIPv4, targetPort);
        _sockets
          ..add(client)
          ..add(upstream);
        client.listen(upstream.add, onDone: upstream.destroy, onError: (_) => upstream.destroy());
        upstream.listen(client.add, onDone: client.destroy, onError: (_) => client.destroy());
      } catch (_) {
        client.destroy();
      }
    });
  }

  /// Stops accepting and destroys every open connection.
  Future<void> cut() async {
    await _listener?.close();
    _listener = null;
    for (final socket in _sockets) {
      socket.destroy();
    }
    _sockets.clear();
  }
}

/// Polls [predicate] against a fresh [Server.statistics] snapshot until it
/// holds (returning the matching snapshot) or [timeout] expires (failing the
/// test with the last snapshot in the message).
Future<ServerStatistics> waitForStats(
  Server server,
  bool Function(ServerStatistics stats) predicate, {
  Duration timeout = const Duration(seconds: 10),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  ServerStatistics stats = server.statistics;
  while (!predicate(stats)) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for ${reason ?? 'statistics condition'}; last: $stats');
    }
    await Future.delayed(const Duration(milliseconds: 50));
    stats = server.statistics;
  }
  return stats;
}

/// Polls until [client] has noticed that its secure channel is gone, which
/// is the point from which open62541 refuses a request before sending it.
/// Fails the test if the channel is still open after [timeout].
Future<void> waitForChannelDown(Client client, {Duration timeout = const Duration(seconds: 10)}) async {
  final deadline = DateTime.now().add(timeout);
  while (client.state.channelState == SecureChannelState.UA_SECURECHANNELSTATE_OPEN) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for the client to notice its secure channel is gone; last: ${client.state}');
    }
    await Future.delayed(const Duration(milliseconds: 20));
  }
}

/// Lists the isolates of the calling suite's isolate group through the VM
/// service.
///
/// ClientIsolate does not expose its worker isolate, and a worker that was
/// never killed is invisible from the outside: it holds an open ReceivePort
/// and simply stays. The VM service is the one place that lists it, so a
/// suite that has to prove a worker is gone switches the service on for its
/// own duration ([start] in setUpAll, [stop] in tearDownAll).
class IsolateWatch {
  IsolateWatch._(this._socket, this._replies, this._disableOnStop);

  final WebSocket _socket;
  final StreamIterator<dynamic> _replies;
  final bool _disableOnStop;
  late final String _groupId;

  static Future<IsolateWatch> start() async {
    final alreadyOn = (await developer.Service.getInfo()).serverWebSocketUri != null;
    final info = await developer.Service.controlWebServer(enable: true, silenceOutput: true);
    final uri = info.serverWebSocketUri;
    if (uri == null) throw StateError('The VM service is not available, cannot list isolates');
    final socket = await WebSocket.connect(uri.toString());
    final watch = IsolateWatch._(socket, StreamIterator(socket), !alreadyOn);
    final self = await watch._call('getIsolate', {'isolateId': developer.Service.getIsolateId(Isolate.current)});
    watch._groupId = self['isolateGroupId'] as String;
    return watch;
  }

  Future<Map<String, dynamic>> _call(String method, Map<String, dynamic> params) async {
    _socket.add(jsonEncode({'jsonrpc': '2.0', 'id': '0', 'method': method, 'params': params}));
    await _replies.moveNext();
    final reply = jsonDecode(_replies.current as String) as Map<String, dynamic>;
    final result = reply['result'];
    if (result is! Map<String, dynamic>) throw StateError('VM service call $method failed: $reply');
    return result;
  }

  /// The ids of the isolates currently alive in this suite's isolate group.
  Future<Set<String>> isolates() async {
    final group = await _call('getIsolateGroup', {'isolateGroupId': _groupId});
    return {for (final isolate in group['isolates'] as List) (isolate as Map)['id'] as String};
  }

  /// Polls until [isolate] is no longer alive; fails the test with [reason]
  /// if it still is after [timeout].
  Future<void> expectGone(
    String isolate, {
    required String reason,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while ((await isolates()).contains(isolate)) {
      if (DateTime.now().isAfter(deadline)) fail(reason);
      await Future.delayed(const Duration(milliseconds: 50));
    }
  }

  Future<void> stop() async {
    await _socket.close();
    if (_disableOnStop) await developer.Service.controlWebServer(enable: false);
  }
}

final boolNodeId = NodeId.fromString(1, "the.bool");
final intNodeId = NodeId.fromString(1, "the.int");
final doubleNodeId = NodeId.fromString(1, "the.double");
final stringNodeId = NodeId.fromString(1, "the.string");

// Not all tests need this and it is annoying me to have this
// be added while I am debugging other tests.
void addBasicVariables(Server server) {
  // Create a boolean variable to read and write
  DynamicValue boolValue = DynamicValue(value: true, typeId: NodeId.boolean, name: "the.bool");
  server.addVariableNode(boolNodeId, boolValue);
  // Create a int variables to read and write
  DynamicValue intValue = DynamicValue(value: 1, typeId: NodeId.int32, name: "the.int");
  server.addVariableNode(intNodeId, intValue);
  // Create a double variables to read and write
  DynamicValue doubleValue = DynamicValue(value: 3.14, typeId: NodeId.double, name: "the.double");
  server.addVariableNode(doubleNodeId, doubleValue);
  // Create a string variables to read and write
  DynamicValue stringValue = DynamicValue(value: "Hello World!", typeId: NodeId.uastring, name: "the.string");
  server.addVariableNode(stringNodeId, stringValue);
}

Server setupServer(int port, {LogLevel logLevel = LogLevel.UA_LOGLEVEL_ERROR}) {
  final server = Server(port: port, logLevel: logLevel);
  server.start();

  // Run the server while we test.
  // runIterate() defaults to a non-blocking poll, so this loop cooperates
  // with other servers/clients pumped on the same isolate. The 50ms delay
  // is REQUIRED to throttle the loop and avoid a 100% CPU busy-spin.
  () async {
    while (server.runIterate()) {
      await Future.delayed(Duration(milliseconds: 50));
    }
  }();
  return server;
}

Future<Client> setupClient(int port, {LogLevel logLevel = LogLevel.UA_LOGLEVEL_FATAL}) async {
  final client = Client(logLevel: logLevel);
  // Run the client while we connect
  () async {
    while (client.runIterate(Duration(milliseconds: 10))) {
      await Future.delayed(Duration(milliseconds: 5));
    }
  }();
  await client.connect("opc.tcp://localhost:$port").onError((error, stackTrace) {
    throw Exception("Failed to connect to the server: $error");
  });

  return client;
}
