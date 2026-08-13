// Verifies the library-side SOLUTIONS to the small-controller session problem:
//   1. a clean close (delete()) frees the controller session slot immediately;
//   2. a SHORT requestedSessionTimeout lets the controller reap an ABANDONED
//      session (a crashed/killed client that never sent CloseSession) in
//      seconds, not the multi-minute vendor default that piles them up;
//   3. our client-side session budget guard fails loud before over-opening.
//
// Runs against a real controller (set PLC_<X>_URL) or a local emulator
// (PLC_<X>_URL=emulator). Session counts are proven via the server's
// CurrentSessionCount (always exposed on the emulator).
@Tags(['plc'])
library;

import 'dart:async';

import 'package:test/test.dart';

import 'plc_config.dart';
import 'plc_fixture.dart';
import 'plc_session.dart';

void main() {
  final targets = PlcConfig.configured();

  tearDownAll(PlcSession.shutdownEmulators);

  if (targets.isEmpty) {
    test('no PLCs configured', () {}, skip: 'Set PLC_TWINCAT_URL / PLC_M240_URL / PLC_M262_URL (or =emulator).');
    return;
  }

  for (final cfg in targets) {
    group('session management [${cfg.name}]', () {
      late PlcSession observer; // one persistent session used to watch the count

      setUpAll(() async {
        observer = await PlcSession.open(cfg);
        // The emulator/PLC publishes CurrentSessionCount on a poll cycle; let it
        // settle so the first test doesn't read a stale value.
        await _settledCount(observer);
      });
      tearDownAll(() async {
        await observer.dispose();
      });

      test('a clean close frees the controller session slot', () async {
        final base = await _settledCount(observer);
        final s = await PlcSession.open(cfg);
        await s.node(PlcFixture.counterName); // do some work
        if (base != null) {
          expect(
            await observer.currentSessionCount(),
            greaterThan(base),
            reason: 'session should be visible on server',
          );
        }
        await s.dispose();
        // The clean CloseSession must free the slot promptly.
        if (base != null) {
          await _eventually(() async => (await observer.currentSessionCount()) == base, const Duration(seconds: 5));
          expect(await observer.currentSessionCount(), base);
        }
      });

      test('a short session timeout reaps an abandoned session', () async {
        final base = await _settledCount(observer);
        if (base == null) {
          markTestSkipped('${cfg.name} does not expose CurrentSessionCount');
          return;
        }

        // A client (wired for this controller's security) with a deliberately
        // tiny session timeout, which we then ABANDON: stop pumping (no
        // keepalive) and never call delete() (no CloseSession) -- i.e. a
        // crashed/killed process.
        final up = await PlcSession.upstream(cfg);
        final client = PlcSession.rawClient(
          cfg,
          requestedSessionTimeout: const Duration(seconds: 4),
          secureChannelLifeTime: const Duration(seconds: 3),
        );
        var running = true;
        unawaited(() async {
          while (running && client.runIterate(const Duration(milliseconds: 10))) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
        }());
        try {
          await client.connect('opc.tcp://${up.host}:${up.port}/').timeout(const Duration(seconds: 20));
        } catch (e) {
          running = false;
          await client.delete();
          rethrow;
        }

        // The session is now live on the controller.
        await _eventually(
          () async => (await observer.currentSessionCount() ?? base) > base,
          const Duration(seconds: 5),
        );
        expect(await observer.currentSessionCount(), greaterThan(base));

        // Abandon it: stop the pump (no keepalive), do NOT close.
        running = false;

        // The controller must reap it within roughly the (short) session timeout.
        await _eventually(
          () async => (await observer.currentSessionCount() ?? (base + 1)) <= base,
          const Duration(seconds: 25),
        );
        expect(
          await observer.currentSessionCount(),
          lessThanOrEqualTo(base),
          reason: 'a short session timeout must let the controller reap an abandoned session',
        );

        await client.delete(); // free native resources (session already gone server-side)
      }, timeout: const Timeout(Duration(seconds: 60)));

      test('session budget guard fails loud before over-opening', () async {
        // Emulator-only: deliberately reaching the cap on real hardware is
        // exactly what we are trying to avoid. Guard in-body (not via `skip:`)
        // because the suite runs with `--run-skipped`, which overrides `skip:`.
        if (!cfg.useEmulator) {
          markTestSkipped('budget-cap test is emulator-only (would stress real hardware)');
          return;
        }
        final sessions = <PlcSession>[];
        try {
          // observer already holds 1; fill up to the cap.
          while ((PlcSession.debugOpenCount(cfg.target)) < cfg.maxSessions) {
            sessions.add(await PlcSession.open(cfg));
          }
          expect(() => PlcSession.open(cfg), throwsA(isA<StateError>()));
        } finally {
          for (final s in sessions) {
            await s.dispose();
          }
        }
      });
    });
  }
}

/// Reads CurrentSessionCount until two consecutive samples agree (the count is
/// published on a poll cycle, so a single read can be stale). Returns null when
/// the server does not expose diagnostics.
Future<int?> _settledCount(PlcSession s) async {
  int? prev;
  for (var i = 0; i < 20; i++) {
    final c = await s.currentSessionCount();
    if (c == null) return null;
    if (c == prev) return c;
    prev = c;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  return prev;
}

/// Polls [cond] until true or [timeout] elapses.
Future<void> _eventually(Future<bool> Function() cond, Duration timeout) async {
  final sw = Stopwatch()..start();
  while (sw.elapsed < timeout) {
    if (await cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}
