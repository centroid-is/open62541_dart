import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';

// Every test server is started with `port: 0` and its port read back through
// `Server.port`: the OS picks a free port and the server holds it from that
// moment, so servers started at the same time by the suites `dart test` runs
// in parallel never share one. A probe that binds port 0, closes, and hands
// the number to a server that binds it moments later is a race: the OS may
// hand the same number out again in between, and open62541's listen sockets
// are SO_REUSEPORT, so two servers given one port BOTH bind it and the
// connections are split between them. See port_allocation_test.dart.

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
/// The access level of the nodes [addBasicVariables] adds: tests write to
/// them through a client, and `addVariableNode` defaults to read-only.
const readWrite = AccessLevelMask(read: true, write: true);

void addBasicVariables(Server server) {
  // Create a boolean variable to read and write
  DynamicValue boolValue = DynamicValue(value: true, typeId: NodeId.boolean, name: "the.bool");
  server.addVariableNode(boolNodeId, boolValue, accessLevel: readWrite);
  // Create a int variables to read and write
  DynamicValue intValue = DynamicValue(value: 1, typeId: NodeId.int32, name: "the.int");
  server.addVariableNode(intNodeId, intValue, accessLevel: readWrite);
  // Create a double variables to read and write
  DynamicValue doubleValue = DynamicValue(value: 3.14, typeId: NodeId.double, name: "the.double");
  server.addVariableNode(doubleNodeId, doubleValue, accessLevel: readWrite);
  // Create a string variables to read and write
  DynamicValue stringValue = DynamicValue(value: "Hello World!", typeId: NodeId.uastring, name: "the.string");
  server.addVariableNode(stringNodeId, stringValue, accessLevel: readWrite);
}

/// Starts a server on a port the OS picks (read it from `Server.port`) and
/// pumps it until it is shut down.
Server setupServer({LogLevel logLevel = LogLevel.UA_LOGLEVEL_ERROR}) {
  final server = Server(port: 0, logLevel: logLevel);
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
  // 127.0.0.1, not localhost: the client connects to the first address the
  // name resolves to (::1 on many hosts), and it is the IPv4 listen socket
  // that owns the OS-picked port; the IPv6 socket binds that number second.
  await client.connect("opc.tcp://127.0.0.1:$port").onError((error, stackTrace) {
    throw Exception("Failed to connect to the server: $error");
  });

  return client;
}

/// The two [ClientApi] implementations, for tests that must hold on both.
const clientTypes = ['direct', 'isolate'];

/// Connects a client of [clientType] (one of [clientTypes]) to [url].
///
/// The direct [Client] is pumped by a loop on this isolate that ends when the
/// client is deleted; [ClientIsolate] pumps itself on its own isolate.
Future<ClientApi> setupClientOfType(
  String clientType,
  String url, {
  LogLevel logLevel = LogLevel.UA_LOGLEVEL_FATAL,
  int schemaCacheSize = Client.defaultSchemaCacheSize,
}) async {
  switch (clientType) {
    case 'isolate':
      final client = await ClientIsolate.create(logLevel: logLevel, schemaCacheSize: schemaCacheSize);
      // runIterate fails once the client is deleted (expected in tearDown).
      unawaited(client.runIterate().catchError((_) {}));
      await client.connect(url);
      return client;
    case 'direct':
      final client = Client(logLevel: logLevel, schemaCacheSize: schemaCacheSize);
      () async {
        while (client.runIterate(Duration(milliseconds: 10))) {
          await Future.delayed(Duration(milliseconds: 5));
        }
      }();
      await client.connect(url);
      return client;
    default:
      throw ArgumentError('Unknown client type: $clientType');
  }
}
