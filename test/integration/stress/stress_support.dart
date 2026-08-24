// Shared helpers for the STRESS category.
//
// Two things live here:
//   * an efficient bulk sensor-tag resolver for the asyncua reference server
//     (browses Plant -> tanks -> each tank's children once, instead of one
//     resolvePath per tag, so resolving hundreds of items stays cheap), and
//   * a self-contained Dart Server + Client pair for the large-payload tests
//     (mirrors complex_types/support.dart; kept local so this category does
//     not depend on another category's files).
//
// Not a test file (no `_test` suffix) so `dart test` ignores it.

import 'dart:async';

import 'package:open62541/open62541.dart';

/// Sensors the asyncua server mutates every update tick (see
/// servers/fish_farm_asyncua.py). Salinity is written once and then static.
const liveSensors = ['Temperature', 'DissolvedOxygen', 'PH', 'WaterLevel'];
const staticSensors = ['Salinity'];
const allSensors = [...liveSensors, ...staticSensors];

/// A resolved sensor tag on a specific tank.
class SensorTag {
  SensorTag(this.label, this.tank, this.sensor, this.nodeId);
  final String label;
  final int tank;
  final String sensor;
  final NodeId nodeId;

  bool get live => liveSensors.contains(sensor);
}

/// Bulk-resolves [sensors] on tanks 1..[tanks] with O(tanks) browses rather
/// than O(tanks*sensors) path walks. Order is tank-major, then [sensors] order.
Future<List<SensorTag>> resolveTankSensors(
  ClientApi client, {
  required int tanks,
  List<String> sensors = allSensors,
}) async {
  // Plant -> Tank* .
  final plant = await _childByName(client, NodeId.objectsFolder, 'Plant');
  final tankChildren = await client.browse(plant);
  final tankIds = <int, NodeId>{};
  for (final c in tankChildren) {
    final m = RegExp(r'^Tank(\d+)$').firstMatch(c.browseName);
    if (m != null) tankIds[int.parse(m.group(1)!)] = c.nodeId;
  }

  final out = <SensorTag>[];
  for (var t = 1; t <= tanks; t++) {
    final tankId = tankIds[t];
    if (tankId == null) {
      throw StateError('Tank$t not found (server exposes tanks ${tankIds.keys.toList()..sort()})');
    }
    final vars = await client.browse(tankId);
    final byName = {for (final v in vars) v.browseName: v.nodeId};
    for (final s in sensors) {
      final id = byName[s];
      if (id == null) throw StateError('Tank$t has no $s (has ${byName.keys.toList()})');
      out.add(SensorTag('Tank$t/$s', t, s, id));
    }
  }
  return out;
}

Future<NodeId> _childByName(ClientApi client, NodeId parent, String name) async {
  final children = await client.browse(parent);
  final match = children.where((c) => c.browseName == name);
  if (match.isEmpty) {
    throw StateError('"$name" not found under $parent (have ${children.map((c) => c.browseName).toList()})');
  }
  return match.first.nodeId;
}

/// Monitored-items request selecting the VALUE attribute of every [nodes].
Map<NodeId, List<AttributeId>> valueParam(Iterable<NodeId> nodes) => {
  for (final n in nodes) n: const [AttributeId.UA_ATTRIBUTEID_VALUE],
};

/// A live Dart [Server] + connected [Client] pair for round-trip tests.
///
/// Both are pumped by fire-and-forget iterate loops. Teardown deletes the
/// client before shutting the server down (the native layer is sensitive to
/// the opposite order).
class ServerClient {
  ServerClient(this.server, this.client, this._stop);

  final Server server;
  final Client client;
  final Future<void> Function() _stop;

  Future<void> dispose() => _stop();
}

Future<ServerClient> startServerClient(
  int port, {
  LogLevel serverLog = LogLevel.UA_LOGLEVEL_ERROR,
  LogLevel clientLog = LogLevel.UA_LOGLEVEL_FATAL,
}) async {
  final server = Server(port: port, logLevel: serverLog);
  server.start();
  var running = true;
  unawaited(() async {
    while (running && server.runIterate()) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }());

  final client = Client(logLevel: clientLog);
  unawaited(() async {
    while (running && client.runIterate(const Duration(milliseconds: 10))) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }());
  await client.connect('opc.tcp://localhost:$port').timeout(const Duration(seconds: 20));

  Future<void> stop() async {
    running = false;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await client.delete();
    server.shutdown();
    server.delete();
  }

  return ServerClient(server, client, stop);
}
