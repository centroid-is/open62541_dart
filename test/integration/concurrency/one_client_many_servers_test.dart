// CONCURRENCY: one process -> many servers.
//
// A single Dart process holds live client connections to several distinct
// servers at once and reads from each concurrently. (The library's `Client` is
// one-connection-per-instance, so "one client" here means one process/isolate
// main holding N client objects — the realistic HMI shape where a gateway
// aggregates several PLC servers.)
//
// Two backends:
//  - Dart `Server` x N, each seeded with a distinct marker value, so we can
//    assert each connection reads *that* server's marker (no server mix-up).
//  - asyncua reference servers x N, reading a live sensor from each.
@Tags(['integration'])
library;

import 'dart:async';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import '../harness/browse_resolver.dart';
import '../harness/dart_client.dart';
import '../harness/net.dart';
import '../harness/paths.dart';
import '../harness/reference_server.dart';
import 'concurrency_support.dart';

final _markerNode = NodeId.fromString(1, 'server.marker');

void main() {
  // ---- Dart servers: deterministic per-server marker ----------------------
  group('1 process -> N Dart servers: distinct marker per server', () {
    test('each connection reads its own server marker, concurrently', () async {
      const serverCount = 3;
      final servers = <DrivenServer>[];
      final clients = <DrivenClient>[];
      try {
        for (var i = 0; i < serverCount; i++) {
          final port = await freePort();
          final marker = 100.0 + i; // unique per server
          final srv = await startDartServer(
            port,
            seed: (s) => s.addVariableNode(
              _markerNode,
              DynamicValue(value: marker, typeId: NodeId.double, name: 'server.marker'),
              accessLevel: AccessLevelMask(read: true, write: true),
            ),
          );
          servers.add(srv);
          clients.add(await connect1(srv.endpoint));
        }

        // Read every server's marker concurrently; each must match its server.
        final reads = <Future<void>>[];
        for (var i = 0; i < serverCount; i++) {
          reads.add(() async {
            final v = await clients[i].client.read(_markerNode);
            expect(v.asDouble, closeTo(100.0 + i, 1e-9), reason: 'connection $i read the wrong server');
          }());
        }
        await Future.wait(reads);

        // Round it out: write a per-connection value on each server and read it
        // back, proving the N connections don't interfere.
        final rw = <Future<void>>[];
        for (var i = 0; i < serverCount; i++) {
          rw.add(() async {
            final want = 500.0 + i;
            await clients[i].client.write(_markerNode, DynamicValue(value: want, typeId: NodeId.double));
            final got = await clients[i].client.read(_markerNode);
            expect(got.asDouble, closeTo(want, 1e-9));
          }());
        }
        await Future.wait(rw);
      } finally {
        await disposeFleet(clients);
        await Future.wait(servers.map((s) => s.stop()));
      }
    }, timeout: const Timeout(Duration(seconds: 120)));
  });

  // ---- asyncua reference servers ------------------------------------------
  group('1 process -> N asyncua servers: read a live sensor from each', () {
    test('concurrent reads across servers all succeed and are in range', () async {
      const serverCount = 2;
      final servers = <ReferenceServer>[];
      final clients = <DrivenClient>[];
      try {
        for (var i = 0; i < serverCount; i++) {
          final srv = ReferenceServer.asyncuaFishFarm(port: await freePort(), tanks: 2, updateMs: 200);
          await srv.start();
          servers.add(srv);
          clients.add(await connect1(srv.endpoint));
        }

        final reads = <Future<void>>[];
        for (var i = 0; i < serverCount; i++) {
          reads.add(() async {
            final tempId = await tankVar(clients[i].client, 1, 'Temperature');
            final v = await clients[i].client.read(tempId);
            expect(v.asDouble, allOf(greaterThan(0), lessThan(100)), reason: 'server $i temp out of range');
          }());
        }
        await Future.wait(reads);
      } finally {
        await disposeFleet(clients);
        await Future.wait(servers.map((s) => s.stop()));
      }
    }, timeout: const Timeout(Duration(seconds: 120)));
  }, skip: asyncuaAvailable() ? false : 'run test/integration/setup_local.sh first');
}
