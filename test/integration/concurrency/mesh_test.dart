// CONCURRENCY: N x M mesh.
//
// M clients, each connected to all N servers at once (M*N live connections in
// one process), driven concurrently. Every server carries a distinct marker so
// each of the M*N connections can prove it is talking to the server it thinks
// it is (no connection mix-up under a dense mesh). Then every client writes a
// per-(client,server) value and reads it back.
//
// Uses deterministic Dart `Server`s so the assertions are exact and the
// footprint stays modest (N*M native servers/clients in one process).
@Tags(['integration'])
library;

import 'dart:async';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import '../harness/dart_client.dart';
import '../harness/net.dart';
import 'concurrency_support.dart';

final _markerNode = NodeId.fromString(1, 'server.marker');
NodeId _cellNode(int client) => NodeId.fromString(1, 'mesh.client.$client');

void main() {
  group('N servers x M clients mesh', () {
    test('every client<->server connection is correct and isolated', () async {
      const serverCount = 2; // N
      const clientCount = 3; // M

      final servers = <DrivenServer>[];
      // clients[m] = the m-th client's connection to each server (length N).
      final clients = <List<DrivenClient>>[];

      try {
        // Bring up N servers; each seeds a distinct marker plus one writable
        // cell node per client.
        for (var n = 0; n < serverCount; n++) {
          final port = await freePort();
          final marker = 1000.0 + n;
          final srv = await startDartServer(
            port,
            seed: (s) {
              s.addVariableNode(
                _markerNode,
                DynamicValue(value: marker, typeId: NodeId.double, name: 'server.marker'),
                accessLevel: AccessLevelMask(read: true, write: true),
              );
              for (var m = 0; m < clientCount; m++) {
                s.addVariableNode(
                  _cellNode(m),
                  DynamicValue(value: 0.0, typeId: NodeId.double, name: 'mesh.client.$m'),
                  accessLevel: AccessLevelMask(read: true, write: true),
                );
              }
            },
          );
          servers.add(srv);
        }

        // Each client opens a connection to every server.
        for (var m = 0; m < clientCount; m++) {
          final conns = await Future.wait(servers.map((s) => connect1(s.endpoint)));
          clients.add(conns);
        }

        // Concurrently: every (client m, server n) pair verifies the marker and
        // round-trips a value unique to that pair.
        final work = <Future<void>>[];
        for (var m = 0; m < clientCount; m++) {
          for (var n = 0; n < serverCount; n++) {
            final client = clients[m][n].client;
            work.add(() async {
              // Marker check: this connection must see server n's marker.
              final marker = await client.read(_markerNode);
              expect(marker.asDouble, closeTo(1000.0 + n, 1e-9), reason: 'client $m/server $n saw wrong marker');

              // Unique value per (m,n): encode both so any mix-up is detectable.
              final want = (m + 1) * 10.0 + n; // e.g. client1@server0 = 10, client2@server1 = 21
              await client.write(_cellNode(m), DynamicValue(value: want, typeId: NodeId.double));
              final got = await client.read(_cellNode(m));
              expect(got.asDouble, closeTo(want, 1e-9), reason: 'client $m/server $n round-trip mismatch');
            }());
          }
        }
        await Future.wait(work);

        // Final cross-check from the servers' own view: each cell holds the
        // value the corresponding client wrote to that server.
        for (var n = 0; n < serverCount; n++) {
          for (var m = 0; m < clientCount; m++) {
            final v = servers[n].server.read(_cellNode(m));
            expect(v.asDouble, closeTo((m + 1) * 10.0 + n, 1e-9), reason: 'server $n cell $m corrupted');
          }
        }
      } finally {
        await disposeFleet(clients.expand((c) => c));
        await Future.wait(servers.map((s) => s.stop()));
      }
    }, timeout: const Timeout(Duration(seconds: 150)));
  });
}
