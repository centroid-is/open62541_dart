// CONCURRENCY: reproduction of the repo's known-failing multi-client basic
// read/write (test/multi_client_test.dart, skipped as "currently failing").
//
// That test brings up several servers, one client each, and has every client
// concurrently write a bool to its own server then read it back. Here we
// reproduce the same shape against BOTH backends to decide whether the failure
// is a library bug or an artefact of the original test:
//   - the Dart `Server` (the original test's backend), and
//   - the asyncua reference server (each client writes its own tank setpoint).
//
// The original test's assertion is embedded inside a detached `.then()` chain
// (the completer completes BEFORE the `expect` runs), so an assertion failure
// escapes as an unhandled async error rather than failing the test. These
// reproductions await every read result and assert synchronously.
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

void main() {
  // ---- Dart Server backend (mirrors the original multi_client_test) --------
  group('multi_client repro on Dart Server', () {
    // The original: N servers, one client each, concurrent write+read of a bool.
    test('N servers x 1 client each: concurrent write/read of own bool', () async {
      const serverCount = 3;
      final servers = <DrivenServer>[];
      final clients = <DrivenClient>[];
      try {
        for (var i = 0; i < serverCount; i++) {
          final port = await freePort();
          final srv = await startDartServer(port, seed: (s) => seedPerClientNodes(s, 1));
          servers.add(srv);
          clients.add(await connect1(srv.endpoint));
        }

        // Each client writes a distinct value to its own server, then reads back.
        final expected = <bool>[];
        final futures = <Future<void>>[];
        for (var i = 0; i < serverCount; i++) {
          final want = i.isEven; // deterministic, distinct per server
          expected.add(want);
          final client = clients[i].client;
          futures.add(() async {
            await client.write(clientBoolNode(0), DynamicValue(value: want, typeId: NodeId.boolean));
            final got = await client.read(clientBoolNode(0));
            expect(got.asBool, want, reason: 'server $i read back the wrong value');
          }());
        }
        await Future.wait(futures);
      } finally {
        await disposeFleet(clients);
        await Future.wait(servers.map((s) => s.stop()));
      }
    }, timeout: const Timeout(Duration(seconds: 90)));

    // The other reading of "multi-client": many clients on ONE server.
    test('1 server x N clients: each client write/reads its own node', () async {
      const clientCount = 4;
      final port = await freePort();
      final server = await startDartServer(port, seed: (s) => seedPerClientNodes(s, clientCount));
      List<DrivenClient> clients = const [];
      try {
        clients = await connectFleet(server.endpoint, clientCount);
        final futures = <Future<void>>[];
        for (var i = 0; i < clientCount; i++) {
          final want = (i + 1) * 1.5;
          final client = clients[i].client;
          futures.add(() async {
            await client.write(clientDoubleNode(i), DynamicValue(value: want, typeId: NodeId.double));
            final got = await client.read(clientDoubleNode(i));
            expect(got.asDouble, closeTo(want, 1e-9), reason: 'client $i read back the wrong value');
          }());
        }
        await Future.wait(futures);

        // Cross-check: no client's write bled into another client's node.
        for (var i = 0; i < clientCount; i++) {
          final got = await clients[i].client.read(clientDoubleNode(i));
          expect(got.asDouble, closeTo((i + 1) * 1.5, 1e-9));
        }
      } finally {
        await disposeFleet(clients);
        await server.stop();
      }
    }, timeout: const Timeout(Duration(seconds: 90)));
  });

  // ---- asyncua backend -----------------------------------------------------
  group('multi_client repro on asyncua', () {
    late ReferenceServer server;

    setUp(() async {
      server = ReferenceServer.asyncuaFishFarm(port: await freePort(), tanks: 4, updateMs: 250);
      await server.start();
    });
    tearDown(() async => server.stop());

    test('N clients each write a distinct tank setpoint and read it back', () async {
      const clientCount = 4;
      List<DrivenClient> clients = const [];
      try {
        clients = await connectFleet(server.endpoint, clientCount);
        final futures = <Future<void>>[];
        for (var i = 0; i < clientCount; i++) {
          final tank = i + 1;
          final want = 10.0 + i; // distinct per client/tank
          final client = clients[i].client;
          futures.add(() async {
            final setId = await tankVar(client, tank, 'TempSetpoint');
            await client.write(setId, DynamicValue(value: want, typeId: NodeId.double));
            final got = await client.read(setId);
            expect(got.asDouble, closeTo(want, 1e-9), reason: 'client $i (tank $tank) read back wrong');
          }());
        }
        await Future.wait(futures);
      } finally {
        await disposeFleet(clients);
      }
    }, timeout: const Timeout(Duration(seconds: 90)));
  }, skip: asyncuaAvailable() ? false : 'run test/integration/setup_local.sh first');
}
