// Shared helpers for the CONCURRENCY category (many clients / many servers).
//
// Not a test file (no `_test` suffix) so `dart test` ignores it.
//
// Provides:
//  - a Dart `Server` brought up on a free port, pumped by a fire-and-forget
//    iterate loop, pre-seeded with per-client writable nodes;
//  - helpers to connect N driven clients of a chosen `ClientKind` mix;
//  - value windows for the asyncua fish-farm live sensors.

import 'dart:async';

import 'package:open62541/open62541.dart';
import '../harness/dart_client.dart';

/// A Dart [Server] plus its pump loop, tracked so tests can tear it down in the
/// correct order (clients first, then server) to avoid native use-after-free.
class DrivenServer {
  DrivenServer(this.server, this.port, this._stop);

  final Server server;
  final int port;
  final Future<void> Function() _stop;

  String get endpoint => 'opc.tcp://localhost:$port';

  Future<void> stop() => _stop();
}

/// Brings up a Dart [Server] on [port], pumped by a fire-and-forget loop.
Future<DrivenServer> startDartServer(
  int port, {
  LogLevel logLevel = LogLevel.UA_LOGLEVEL_ERROR,
  void Function(Server server)? seed,
}) async {
  final server = Server(port: port, logLevel: logLevel);
  server.start();
  seed?.call(server);
  var running = true;
  unawaited(() async {
    // waitInterval:false makes each iterate a non-blocking poll. This is
    // essential when several Dart Servers share one isolate: the blocking
    // default (UA_Server_run_iterate with waitInterval=true) parks the isolate
    // thread waiting for I/O, so sibling servers never get pumped and connects
    // to them stall (measured: connect latency 0.18s -> 2.3s -> timeout as the
    // count grows). Polling lets all servers time-share fairly.
    while (running && server.runIterate(waitInterval: false)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }());
  // Give the listen socket a moment to come up before any client connects.
  await Future<void>.delayed(const Duration(milliseconds: 200));

  Future<void> stop() async {
    running = false;
    await Future<void>.delayed(const Duration(milliseconds: 40));
    server.shutdown();
    server.delete();
  }

  return DrivenServer(server, port, stop);
}

/// NodeId for a per-client writable double node (`client.<i>.value`).
NodeId clientDoubleNode(int i) => NodeId.fromString(1, 'client.$i.value');

/// NodeId for a per-client writable bool node (`client.<i>.flag`).
NodeId clientBoolNode(int i) => NodeId.fromString(1, 'client.$i.flag');

/// NodeId for a single shared writable double node all clients contend on.
final sharedDoubleNode = NodeId.fromString(1, 'shared.value');

/// Seeds [count] per-client writable double + bool nodes plus one shared node.
void seedPerClientNodes(Server server, int count) {
  for (var i = 0; i < count; i++) {
    server.addVariableNode(
      clientDoubleNode(i),
      DynamicValue(value: 0.0, typeId: NodeId.double, name: 'client.$i.value'),
      accessLevel: AccessLevelMask(read: true, write: true),
    );
    server.addVariableNode(
      clientBoolNode(i),
      DynamicValue(value: false, typeId: NodeId.boolean, name: 'client.$i.flag'),
      accessLevel: AccessLevelMask(read: true, write: true),
    );
  }
  server.addVariableNode(
    sharedDoubleNode,
    DynamicValue(value: 0.0, typeId: NodeId.double, name: 'shared.value'),
    accessLevel: AccessLevelMask(read: true, write: true),
  );
}

/// A deliberately generous connect timeout. The harness default is 20s, which
/// this shared box can blow past when several servers/clients come up at once
/// under load; 60s keeps contention from masquerading as a connect bug.
const generousConnect = Duration(seconds: 60);

/// Connects a single driven client with the generous connect timeout.
Future<DrivenClient> connect1(String url, {ClientKind kind = ClientKind.direct}) =>
    connectClient(url, kind: kind, connectTimeout: generousConnect);

/// Connects [count] clients, assigning kinds from [kinds] round-robin.
/// Defaults to all-direct. Use `[ClientKind.direct, ClientKind.isolate]` for a
/// mixed fleet.
Future<List<DrivenClient>> connectFleet(
  String url,
  int count, {
  List<ClientKind> kinds = const [ClientKind.direct],
  Duration connectTimeout = generousConnect,
}) async {
  final futures = <Future<DrivenClient>>[];
  for (var i = 0; i < count; i++) {
    final kind = kinds[i % kinds.length];
    futures.add(connectClient(url, kind: kind, connectTimeout: connectTimeout));
  }
  return Future.wait(futures);
}

/// Tears down a fleet of clients, swallowing individual dispose errors so one
/// bad client cannot block the rest of teardown.
Future<void> disposeFleet(Iterable<DrivenClient> clients) async {
  await Future.wait(clients.map((c) => c.dispose().catchError((_) {})));
}
