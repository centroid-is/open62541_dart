// CONCURRENCY: many clients -> one server.
//
// Fans out N driven clients against a single server and drives them
// concurrently, asserting there is no cross-talk: each client reads back
// exactly the value IT wrote, and each client's subscription only ever sees its
// own node's values.
//
// Group A runs against the asyncua reference server, parameterized over an
// all-direct fleet, an all-isolate fleet, and a mixed fleet (per the brief).
// Group B uses a deterministic Dart `Server` to make the subscription
// cross-talk assertion exact (values are server-driven, not sampled live data).
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
  // ---- Group A: asyncua, across direct / isolate / mixed fleets ------------
  group('N clients -> 1 asyncua server', () {
    const clientCount = 3; // tanks default = 3 -> one tank per client
    late ReferenceServer server;

    setUp(() async {
      server = ReferenceServer.asyncuaFishFarm(port: await freePort(), tanks: clientCount, updateMs: 200);
      await server.start();
    });
    tearDown(() async => server.stop());

    final fleets = <String, List<ClientKind>>{
      'direct': [ClientKind.direct],
      'isolate': [ClientKind.isolate],
      'mixed': [ClientKind.direct, ClientKind.isolate],
    };

    for (final entry in fleets.entries) {
      test('${entry.key} fleet: concurrent write/read/subscribe, no cross-talk', () async {
        List<DrivenClient> clients = const [];
        try {
          clients = await connectFleet(server.endpoint, clientCount, kinds: entry.value);

          // Each client owns a distinct tank. It writes a distinct setpoint,
          // reads it back, and subscribes to that tank's live Temperature.
          final work = <Future<void>>[];
          for (var i = 0; i < clientCount; i++) {
            final tank = i + 1;
            final wantSetpoint = 11.0 + i; // distinct per client
            final client = clients[i].client;
            work.add(() async {
              final setId = await tankVar(client, tank, 'TempSetpoint');
              final tempId = await tankVar(client, tank, 'Temperature');

              await client.write(setId, DynamicValue(value: wantSetpoint, typeId: NodeId.double));

              // Subscribe to this tank's live temperature and collect a few.
              final subId = await client.subscriptionCreate(
                requestedPublishingInterval: const Duration(milliseconds: 100),
              );
              final seen = <double>[];
              final gotOne = Completer<void>();
              final sub = client.monitor(tempId, subId, samplingInterval: const Duration(milliseconds: 100)).listen((
                v,
              ) {
                seen.add(v.asDouble);
                if (!gotOne.isCompleted) gotOne.complete();
              });

              // Read the setpoint back: must equal exactly what THIS client wrote.
              final readBack = await client.read(setId);
              expect(readBack.asDouble, closeTo(wantSetpoint, 1e-9), reason: 'client $i cross-talk on setpoint');

              await gotOne.future.timeout(const Duration(seconds: 20));
              await sub.cancel();

              expect(seen, isNotEmpty, reason: 'client $i saw no subscription updates');
              for (final t in seen) {
                expect(t, allOf(greaterThan(0), lessThan(100)), reason: 'client $i implausible temp $t');
              }
            }());
          }
          await Future.wait(work);
        } finally {
          await disposeFleet(clients);
        }
      }, timeout: const Timeout(Duration(seconds: 120)));
    }
  }, skip: asyncuaAvailable() ? false : 'run test/integration/setup_local.sh first');

  // ---- Group B: deterministic subscription cross-talk on a Dart Server -----
  group('N clients -> 1 Dart server: deterministic subscription cross-talk', () {
    test('each client only sees its own node updates', () async {
      const clientCount = 4;
      final port = await freePort();
      final server = await startDartServer(port, seed: (s) => seedPerClientNodes(s, clientCount));
      List<DrivenClient> clients = const [];
      try {
        clients = await connectFleet(server.endpoint, clientCount);

        // Each client subscribes to its own bool node and writes a distinct
        // 4-value pattern; its stream must emit exactly that pattern in order.
        final patterns = <int, List<bool>>{
          for (var i = 0; i < clientCount; i++) i: [i.isEven, i.isOdd, i.isEven, i.isOdd],
        };

        final work = <Future<void>>[];
        for (var i = 0; i < clientCount; i++) {
          final client = clients[i].client;
          final node = clientBoolNode(i);
          final pattern = patterns[i]!;
          work.add(() async {
            // Prime the value to the opposite of pattern[0] so the first write
            // is an observable change.
            await client.write(node, DynamicValue(value: !pattern.first, typeId: NodeId.boolean));
            final subId = await client.subscriptionCreate(
              requestedPublishingInterval: const Duration(milliseconds: 20),
            );
            final received = <bool>[];
            final done = Completer<void>();
            final sub = client.monitor(node, subId, samplingInterval: const Duration(milliseconds: 20)).listen((v) {
              received.add(v.asBool);
              if (received.length >= pattern.length && !done.isCompleted) done.complete();
            });

            for (final b in pattern) {
              await client.write(node, DynamicValue(value: b, typeId: NodeId.boolean));
              await Future<void>.delayed(const Duration(milliseconds: 120));
            }
            await done.future.timeout(const Duration(seconds: 20));
            await sub.cancel();

            // The tail of what we received must be exactly our own pattern:
            // every value belongs to this client's node (no cross-talk), and
            // the last `pattern.length` entries match the written sequence.
            expect(received.length, greaterThanOrEqualTo(pattern.length));
            final tail = received.sublist(received.length - pattern.length);
            expect(tail, pattern, reason: 'client $i saw wrong/mixed values: $received');
          }());
        }
        await Future.wait(work);
      } finally {
        await disposeFleet(clients);
        await server.stop();
      }
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
}
