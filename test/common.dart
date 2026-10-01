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
///
/// The probe binds the wildcard address, because that is what the servers
/// under test bind. A port can be free on loopback and taken on the wildcard
/// address, and a loopback probe then hands out a port the server cannot
/// bind: seen on a macOS CI runner as "Error binding the socket ... (Address
/// already in use)" from the server, followed by "Could not open a TCP
/// connection" from its client.
Future<int> freeTcpPort() async {
  final socket = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

/// A TCP proxy in front of [targetPort], so a test can take a client's
/// connection away, and with it the secure channel, without stopping the
/// server. The server keeps the session and its monitored items, and the
/// client re-activates that session once the proxy lets it through again
/// ([resume]). Left cut, it is a dead connection: the client keeps trying to
/// reconnect and gets nowhere.
///
/// The proxy binds its port once and keeps it until the test ends. While cut
/// it still accepts, and destroys what it accepts. Giving the port back while
/// a client is still reconnecting to it would let that client wander into
/// whatever another suite starts on the recycled port: `dart test` runs
/// suites in parallel.
class TcpProxy {
  TcpProxy._(this._listener, this.targetPort);

  final ServerSocket _listener;
  final int targetPort;
  final List<Socket> _sockets = [];
  bool _cut = false;
  bool _stalled = false;

  /// The port clients connect to, on 127.0.0.1.
  int get port => _listener.port;

  static Future<TcpProxy> start(int targetPort) async {
    final proxy = TcpProxy._(await ServerSocket.bind(InternetAddress.anyIPv4, 0), targetPort);
    proxy._listener.listen(proxy._accept);
    addTearDown(proxy._close);
    return proxy;
  }

  Future<void> _accept(Socket client) async {
    // A destroyed peer makes a later write fail; that error only surfaces on
    // `done`, and nobody else is listening for it.
    client.done.ignore();
    if (_cut) {
      client.destroy();
      return;
    }
    final Socket upstream;
    try {
      upstream = await Socket.connect(InternetAddress.loopbackIPv4, targetPort);
    } catch (_) {
      client.destroy();
      return;
    }
    upstream.done.ignore();
    if (_cut) {
      client.destroy();
      upstream.destroy();
      return;
    }
    _sockets
      ..add(client)
      ..add(upstream);
    client.listen(
      (data) => _stalled ? null : upstream.add(data),
      onDone: upstream.destroy,
      onError: (_) => upstream.destroy(),
    );
    upstream.listen(
      (data) => _stalled ? null : client.add(data),
      onDone: client.destroy,
      onError: (_) => client.destroy(),
    );
  }

  /// Keeps the open connections but drops everything sent on them from now
  /// on, in both directions: a black-holed link. [cut] then [resume] ends it.
  void stall() => _stalled = true;

  /// Destroys every open connection, and every new one as it arrives.
  void cut() {
    _cut = true;
    for (final socket in _sockets) {
      socket.destroy();
    }
    _sockets.clear();
  }

  /// Forwards new connections to [targetPort] again.
  void resume() {
    _cut = false;
    _stalled = false;
  }

  Future<void> _close() async {
    cut();
    await _listener.close();
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
/// suite that has to prove a worker is gone switches the service on ([start]
/// in setUpAll, [stop] in tearDownAll).
///
/// The service is left on afterwards: `dart test` runs every suite in one
/// process, so another suite may be using it at that moment.
class IsolateWatch {
  IsolateWatch._(this._socket, this._replies);

  final WebSocket _socket;
  final StreamIterator<dynamic> _replies;
  late final String _groupId;

  static Future<IsolateWatch> start() async {
    final info = await developer.Service.controlWebServer(enable: true, silenceOutput: true);
    final uri = info.serverWebSocketUri;
    if (uri == null) throw StateError('The VM service is not available, cannot list isolates');
    final socket = await WebSocket.connect(uri.toString());
    final watch = IsolateWatch._(socket, StreamIterator(socket));
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

  Future<void> stop() => _socket.close();
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
