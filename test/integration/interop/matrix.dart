// Shared INTEROP test body: the Dart client exercised against an independent
// OPC UA server stack (asyncua or node-opcua). Both stacks host the identical
// fish-farm model, addressed by BrowseName, so one parameterized matrix proves
// interop for either. The stack-specific `*_test.dart` files just call
// [registerInteropMatrix] with the right server factory + skip guard.
//
// This is a helper library (imported, not run directly), so it has no `main`.

import 'dart:async';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import '../harness/browse_resolver.dart';
import '../harness/dart_client.dart';
import '../harness/net.dart';
import '../harness/reference_server.dart';

typedef ServerFactory = ReferenceServer Function(int port);

/// The per-tank browse names in the shared fish-farm model.
const _sensors = ['Temperature', 'DissolvedOxygen', 'PH', 'Salinity', 'WaterLevel'];
const _tankVars = [..._sensors, 'TempSetpoint', 'PumpRunning', 'AlarmActive', 'AlarmMessage', 'AlarmSeverity'];
const _tankMethods = ['FeedNow', 'ResetAlarm'];

/// Registers the full client-side interop matrix for [stack], parameterized
/// over both [ClientKind]s. [makeServer] builds a live reference server on a
/// given port; [tanks] is how many tanks that server exposes.
void registerInteropMatrix({
  required String stack,
  required ServerFactory makeServer,
  required int tanks,
  Object? skip,
}) {
  for (final kind in clientTypes) {
    group('$stack interop [$kind]', () {
      late ReferenceServer server;
      late DrivenClient dc;
      ClientApi client() => dc.client;

      setUpAll(() async {
        server = makeServer(await freePort());
        await server.start();
        dc = await _connectGuarded(server.endpoint, kind);
      });

      tearDownAll(() async {
        await dc.dispose();
        await server.stop();
      });

      test('browse the full fish-farm tree', () async {
        // Objects -> Plant.
        final plant = await resolvePath(client(), ['Plant']);

        // Plant -> exactly `tanks` tank objects.
        final tankChildren = await client().browse(plant);
        final tankNames = tankChildren.map((c) => c.browseName).where((n) => n.startsWith('Tank')).toSet();
        expect(tankNames, {for (var i = 1; i <= tanks; i++) 'Tank$i'}, reason: 'Plant should expose Tank1..Tank$tanks');

        // Each tank exposes every variable and method by BrowseName.
        for (var i = 1; i <= tanks; i++) {
          final tank = await resolvePath(client(), ['Plant', 'Tank$i']);
          final children = await client().browse(tank);
          final names = children.map((c) => c.browseName).toSet();
          for (final v in _tankVars) {
            expect(names, contains(v), reason: 'Tank$i missing variable $v');
          }
          for (final m in _tankMethods) {
            expect(names, contains(m), reason: 'Tank$i missing method $m');
          }
          // Methods are exposed as Method nodes.
          for (final m in _tankMethods) {
            final node = children.firstWhere((c) => c.browseName == m);
            expect(node.nodeClass, NodeClass.UA_NODECLASS_METHOD, reason: '$m should be a Method node');
          }
        }
      }, timeout: const Timeout(Duration(seconds: 60)));

      test('read every sensor on every tank', () async {
        for (var i = 1; i <= tanks; i++) {
          for (final s in _sensors) {
            final v = await client().read(await tankVar(client(), i, s));
            expect(v.value, isA<double>(), reason: 'Tank$i/$s should read as a Double');
            expect(v.asDouble.isFinite, isTrue);
          }
        }
      }, timeout: const Timeout(Duration(seconds: 60)));

      test('write TempSetpoint and read it back', () async {
        final id = await tankVar(client(), 1, 'TempSetpoint');
        for (final target in [9.25, 15.75, 11.0]) {
          await client().write(id, DynamicValue(value: target, typeId: NodeId.double));
          final back = await client().read(id);
          expect(back.asDouble, closeTo(target, 1e-9), reason: 'TempSetpoint round-trip should be exact');
        }
      }, timeout: const Timeout(Duration(seconds: 60)));

      test('write PumpRunning and read it back', () async {
        final id = await tankVar(client(), 1, 'PumpRunning');
        for (final target in [false, true, false]) {
          await client().write(id, DynamicValue(value: target, typeId: NodeId.boolean));
          final back = await client().read(id);
          expect(back.value, isA<bool>());
          expect(back.asBool, target, reason: 'PumpRunning round-trip');
        }
      }, timeout: const Timeout(Duration(seconds: 60)));

      test('call FeedNow with argument fidelity (grams >= 0 -> accepted)', () async {
        final tank = await resolvePath(client(), ['Plant', 'Tank1']);
        final feed = await tankMethod(client(), 1, 'FeedNow');

        // A non-negative amount is accepted...
        final accepted = await client().call(tank, feed, [DynamicValue(value: 42.0, typeId: NodeId.double)]);
        expect(accepted, hasLength(1));
        expect(accepted.first.value, isA<bool>());
        expect(accepted.first.asBool, isTrue, reason: 'FeedNow(42.0) should be accepted');

        // ...a negative amount is rejected. This only differs from the above if
        // the argument actually crossed the wire, so it proves arg fidelity.
        final rejected = await client().call(tank, feed, [DynamicValue(value: -5.0, typeId: NodeId.double)]);
        expect(
          rejected.first.asBool,
          isFalse,
          reason: 'FeedNow(-5.0) should be rejected -> proves the Double arg reached the server',
        );
      }, timeout: const Timeout(Duration(seconds: 60)));

      test('call ResetAlarm (no args -> ok)', () async {
        final tank = await resolvePath(client(), ['Plant', 'Tank1']);
        final reset = await tankMethod(client(), 1, 'ResetAlarm');
        final result = await client().call(tank, reset, const []);
        expect(result, hasLength(1));
        expect(result.first.asBool, isTrue);
      }, timeout: const Timeout(Duration(seconds: 60)));

      test('subscribe to a live sensor and see changing values', () async {
        final tempId = await tankVar(client(), 1, 'Temperature');
        final subId = await client().subscriptionCreate(requestedPublishingInterval: const Duration(milliseconds: 100));
        final seen = <double>[];
        final gotEnough = Completer<void>();
        final sub = client().monitor(tempId, subId, samplingInterval: const Duration(milliseconds: 100)).listen((v) {
          seen.add(v.asDouble);
          // At least 3 distinct samples => the value is genuinely live.
          if (seen.toSet().length >= 3 && !gotEnough.isCompleted) {
            gotEnough.complete();
          }
        });

        try {
          await gotEnough.future.timeout(
            const Duration(seconds: 20),
            onTimeout: () => fail('did not observe >=3 distinct live values; saw $seen'),
          );
        } finally {
          await sub.cancel();
        }
        expect(seen.toSet().length, greaterThanOrEqualTo(3));
      }, timeout: const Timeout(Duration(seconds: 40)));

      test('data-type fidelity: Double / Bool / String / UInt16', () async {
        // Double sensor.
        final temp = await client().read(await tankVar(client(), 1, 'Temperature'));
        expect(temp.value, isA<double>());

        // Boolean.
        final alarm = await client().read(await tankVar(client(), 1, 'AlarmActive'));
        expect(alarm.value, isA<bool>());

        // String.
        final msg = await client().read(await tankVar(client(), 1, 'AlarmMessage'));
        expect(msg.value, isA<String>());

        // UInt16 surfaces as a Dart int.
        final sev = await client().read(await tankVar(client(), 1, 'AlarmSeverity'));
        expect(sev.value, isA<int>());
        expect(sev.asInt, greaterThanOrEqualTo(0));

        // Round-trip a Double and a Bool preserves the runtime type end to end.
        final setId = await tankVar(client(), 1, 'TempSetpoint');
        await client().write(setId, DynamicValue(value: 7.5, typeId: NodeId.double));
        expect((await client().read(setId)).value, isA<double>());

        final pumpId = await tankVar(client(), 1, 'PumpRunning');
        await client().write(pumpId, DynamicValue(value: true, typeId: NodeId.boolean));
        expect((await client().read(pumpId)).value, isA<bool>());
      }, timeout: const Timeout(Duration(seconds: 60)));
    }, skip: skip);
  }
}

/// Brings up a connected [DrivenClient] of [kind], mirroring the harness's
/// `connectClient` but guarding the isolate's fire-and-forget `runIterate`
/// loop with `.catchError`. Without that guard, disposing the isolate errors
/// the pending `runIterate` with `ClientIsolateClosedException`
/// (lib/src/isolate.dart:632), which escapes as an uncaught zone error during
/// teardown. The harness's `connectClient` (test/integration/harness/
/// dart_client.dart:54) omits this guard; `test/async_integration_test.dart:22`
/// includes it. Reported as a harness gap; not modifiable from here.
Future<DrivenClient> _connectGuarded(
  String url,
  ClientKind kind, {
  Duration iterate = const Duration(milliseconds: 10),
  Duration connectTimeout = const Duration(seconds: 20),
}) async {
  switch (kind) {
    case ClientKind.direct:
      final client = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
      var running = true;
      unawaited(() async {
        while (running && client.runIterate(iterate)) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }());
      await client.connect(url).timeout(connectTimeout);
      return DrivenClient(client, () async {
        running = false;
        await client.delete();
      }, kind);

    case ClientKind.isolate:
      final client = await ClientIsolate.create(logLevel: LogLevel.UA_LOGLEVEL_FATAL, iterateInterval: iterate);
      unawaited(client.runIterate(duration: iterate).catchError((_) {}));
      await client.connect(url).timeout(connectTimeout);
      return DrivenClient(client, () async {
        await client.delete();
      }, kind);
  }
}
