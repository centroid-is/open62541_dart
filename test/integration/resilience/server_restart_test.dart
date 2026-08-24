// RESILIENCE: server crash (SIGKILL) and restart on the same port underneath a
// live client.
//
// Behaviour established empirically (see recovery_support.dart for the root
// cause): open62541 does NOT self-recover across a server gap. A real client
// must keep its event loop pumped and call connect() again. These tests assert
// that application-driven reconnection genuinely restores the session
// (stateStream returns to ACTIVATED) and that reads work again afterwards, and
// one test positively documents the no-auto-recovery limitation.
@Tags(['integration'])
library;

import 'dart:async';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import '../harness/browse_resolver.dart';
import '../harness/net.dart';
import '../harness/paths.dart';
import '../harness/reference_server.dart';
import 'recovery_support.dart';

void main() {
  group('server crash + restart (asyncua)', () {
    late ReferenceServer server;

    setUp(() async {
      server = ReferenceServer.asyncuaFishFarm(port: await freePort(), tanks: 2, updateMs: 150);
      await server.start();
    });

    tearDown(() async {
      await server.stop();
    });

    // Core scenario, for both client kinds: crash the server mid-session and
    // restart it on the same port; app-driven reconnect must bring the session
    // back to ACTIVATED and reads must work again.
    for (final kind in clientTypes) {
      test('crash + restart mid-session recovers reads [$kind]', () async {
        final rc = await ResilientClient.connect(server.endpoint, kind: kind);
        try {
          final tempId = await tankVar(rc.client, 1, 'Temperature');
          final before = await rc.client.read(tempId);
          expect(before.asDouble, allOf(greaterThan(0), lessThan(100)));

          // Arm a drop detector before the crash (broadcast stream).
          final dropped = rc.stateStream.firstWhere((s) => !isActivated(s));

          // SIGKILL the server and bring it back on the same port.
          await server.restart();

          // The client must observe the session leaving ACTIVATED.
          await dropped.timeout(const Duration(seconds: 15));

          // Application-driven reconnect.
          await rc.reconnect(server.endpoint, timeout: const Duration(seconds: 25));

          final state = await rc.currentState();
          expect(isActivated(state), isTrue, reason: 'session should be ACTIVATED after reconnect, was $state');

          // Reads work again post-recovery.
          final after = await rc.client.read(tempId).timeout(const Duration(seconds: 10));
          expect(after.asDouble, allOf(greaterThan(0), lessThan(100)));

          // And writes/round-trips work too.
          final setId = await tankVar(rc.client, 1, 'TempSetpoint');
          await rc.client.write(setId, DynamicValue(value: 12.25, typeId: NodeId.double));
          final readback = await rc.client.read(setId);
          expect(readback.asDouble, closeTo(12.25, 1e-9));
        } finally {
          await rc.dispose();
        }
      }, timeout: const Timeout(Duration(seconds: 120)));
    }

    // Positively documents the limitation: with NO application intervention the
    // client does not climb back to ACTIVATED on its own after a crash+restart.
    // If open62541 ever gains real auto-reconnect this test will start failing,
    // which is the desired signal to revisit the recovery strategy.
    test('no self-recovery: session stays down until the app reconnects', () async {
      final rc = await ResilientClient.connect(server.endpoint);
      try {
        final tempId = await tankVar(rc.client, 1, 'Temperature');
        await rc.client.read(tempId);

        final dropped = rc.stateStream.firstWhere((s) => !isActivated(s));
        await server.restart();
        await dropped.timeout(const Duration(seconds: 15));

        // The pump keeps running (it ignores the bad status), but the C client
        // has given up reconnecting. Give it a generous window and confirm it
        // never re-activates on its own.
        var reactivated = false;
        try {
          await rc.stateStream.firstWhere(isActivated).timeout(const Duration(seconds: 8));
          reactivated = true;
        } on TimeoutException {
          reactivated = false;
        }
        expect(
          reactivated,
          isFalse,
          reason:
              'open62541 is expected NOT to auto-reconnect after the peer went away; '
              'if this now recovers on its own, update the recovery strategy',
        );

        // Sanity: the app-driven path still works from this state.
        await rc.reconnect(server.endpoint, timeout: const Duration(seconds: 25));
        expect(isActivated(await rc.currentState()), isTrue);
        expect((await rc.client.read(tempId)).asDouble, isNotNull);
      } finally {
        await rc.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 120)));

    // Restart WITH downtime: the client must not "recover" before the server is
    // actually back, and must recover once it returns.
    test('restart with downtime: reconnect only succeeds after the server returns', () async {
      final rc = await ResilientClient.connect(server.endpoint);
      try {
        final tempId = await tankVar(rc.client, 1, 'Temperature');
        await rc.client.read(tempId);

        // Arm a drop detector, then take the server down and keep it down.
        final dropped = rc.stateStream.firstWhere((s) => !isActivated(s));
        await server.stop();

        // Wait until the client has actually observed the drop. (Immediately
        // after stop() the C client still reports the stale ACTIVATED session,
        // which would make connect()'s awaitConnect() short-circuit.)
        await dropped.timeout(const Duration(seconds: 15));
        expect(isActivated(await rc.currentState()), isFalse);

        // While it is down, a connect attempt must fail (not hang, not falsely
        // succeed).
        var connectedWhileDown = false;
        try {
          await rc.client.connect(server.endpoint).timeout(const Duration(seconds: 3));
          connectedWhileDown = true;
        } catch (_) {
          connectedWhileDown = false;
        }
        expect(connectedWhileDown, isFalse, reason: 'must not connect while the server is down');
        expect(isActivated(await rc.currentState()), isFalse);

        // Real downtime, then bring it back.
        await Future<void>.delayed(const Duration(seconds: 3));
        await server.start();

        await rc.reconnect(server.endpoint, timeout: const Duration(seconds: 25));
        expect(isActivated(await rc.currentState()), isTrue);
        expect((await rc.client.read(tempId)).asDouble, allOf(greaterThan(0), lessThan(100)));
      } finally {
        await rc.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 120)));

    // Repeated crash/restart cycles: the client must stay stable and recover
    // every time (no leaks/crashes/hangs across iterations).
    test('repeated crash/restart cycles (4x) recover each time', () async {
      final rc = await ResilientClient.connect(server.endpoint);
      try {
        final tempId = await tankVar(rc.client, 1, 'Temperature');
        expect((await rc.client.read(tempId)).asDouble, isNotNull);

        for (var i = 0; i < 4; i++) {
          final dropped = rc.stateStream.firstWhere((s) => !isActivated(s));
          await server.restart();
          await dropped.timeout(const Duration(seconds: 15));

          await rc.reconnect(server.endpoint, timeout: const Duration(seconds: 25));
          expect(isActivated(await rc.currentState()), isTrue, reason: 'cycle $i: not activated');

          final v = await rc.client.read(tempId).timeout(const Duration(seconds: 10));
          expect(v.asDouble, allOf(greaterThan(0), lessThan(100)), reason: 'cycle $i: bad read');
        }
      } finally {
        await rc.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 240)));
  }, skip: asyncuaAvailable() ? false : 'run test/integration/setup_local.sh first');
}
