// HMI "Setpoint round-trip" scenario.
//
// An operator on one panel writes TempSetpoint and toggles PumpRunning; a
// second client watching the same nodes must see the change (write-through
// visibility) -- once via a live subscription (push) and once via a direct
// read (pull).
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

void main() {
  group('HMI setpoint round-trip', () {
    late ReferenceServer server;

    setUp(() async {
      server = ReferenceServer.asyncuaFishFarm(port: await freePort(), tanks: 2, updateMs: 250);
      await server.start();
    });

    tearDown(() async {
      await server.stop();
    });

    for (final kind in clientTypes) {
      test('TempSetpoint write is seen by a subscribed observer ($kind)', () async {
        final writer = await connectClient(server.endpoint, kind: kind);
        final observer = await connectClient(server.endpoint, kind: kind);
        StreamSubscription<DynamicValue>? sub;
        try {
          final setId = await tankVar(writer.client, 1, 'TempSetpoint');

          final subId = await observer.client.subscriptionCreate(
            requestedPublishingInterval: const Duration(milliseconds: 200),
          );
          final stream = observer.client.monitor(setId, subId, samplingInterval: const Duration(milliseconds: 200));

          final seen = <double>[];

          // Two distinct setpoints, neither equal to the 12.0 baseline.
          const target1 = 15.5;
          const target2 = 9.25;
          final got1 = Completer<void>();
          final got2 = Completer<void>();

          sub = stream.listen((v) {
            final d = v.asDouble;
            seen.add(d);
            if ((d - target1).abs() < 1e-6 && !got1.isCompleted) got1.complete();
            if ((d - target2).abs() < 1e-6 && !got2.isCompleted) got2.complete();
          });

          // Let the observer establish its baseline read (12.0).
          await Future<void>.delayed(const Duration(milliseconds: 600));
          expect(seen, isNotEmpty, reason: 'observer never received the baseline setpoint');

          // Operator writes a new setpoint; observer must be pushed the value.
          await writer.client.write(setId, DynamicValue(value: target1, typeId: NodeId.double));
          await got1.future.timeout(
            const Duration(seconds: 10),
            onTimeout: () => fail('observer never saw setpoint $target1 (saw $seen)'),
          );
          expect((await writer.client.read(setId)).asDouble, closeTo(target1, 1e-6));

          // A second write also propagates.
          await writer.client.write(setId, DynamicValue(value: target2, typeId: NodeId.double));
          await got2.future.timeout(
            const Duration(seconds: 10),
            onTimeout: () => fail('observer never saw setpoint $target2 (saw $seen)'),
          );
          expect((await observer.client.read(setId)).asDouble, closeTo(target2, 1e-6));
        } finally {
          await sub?.cancel();
          await writer.dispose();
          await observer.dispose();
        }
      }, timeout: const Timeout(Duration(seconds: 60)));

      test('PumpRunning toggle is visible via read-through ($kind)', () async {
        final writer = await connectClient(server.endpoint, kind: kind);
        final observer = await connectClient(server.endpoint, kind: kind);
        try {
          final pumpId = await tankVar(writer.client, 1, 'PumpRunning');

          // Baseline: pump starts running.
          expect((await observer.client.read(pumpId)).asBool, isTrue);

          // Operator stops the pump; a second panel reading the node sees it.
          await writer.client.write(pumpId, DynamicValue(value: false, typeId: NodeId.boolean));
          expect((await observer.client.read(pumpId)).asBool, isFalse, reason: 'observer did not see pump stop');

          // And restart round-trips back.
          await writer.client.write(pumpId, DynamicValue(value: true, typeId: NodeId.boolean));
          expect((await observer.client.read(pumpId)).asBool, isTrue, reason: 'observer did not see pump restart');
        } finally {
          await writer.dispose();
          await observer.dispose();
        }
      }, timeout: const Timeout(Duration(seconds: 60)));
    }
  }, skip: asyncuaAvailable() ? false : 'run test/integration/setup_local.sh first');
}
