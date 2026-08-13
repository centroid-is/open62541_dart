// Verifies the library-side SOLUTIONS to the small-controller session problem:
//   1. a clean close (delete()) frees the controller session slot immediately;
//   2. the leased client (LeasedPlcClient) holds NO session while idle, so an
//      occasional-poll HMI never squats a slot;
//   3. our client-side session budget guard fails loud before over-opening.
//
// Runs against a real controller (set PLC_<X>_URL) or a local emulator
// (PLC_<X>_URL=emulator). Session counts are proven via the server's
// CurrentSessionCount where exposed (always on the emulator); the leased-client
// release is also asserted client-side (hasOpenSession), so it is verified even
// on controllers that don't publish diagnostics.
@Tags(['plc'])
library;

import 'package:test/test.dart';

import 'plc_client.dart';
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

      test('leased client holds NO session while idle', () async {
        final base = await _settledCount(observer);
        final leased = LeasedPlcClient(cfg, idle: const Duration(milliseconds: 400));
        try {
          expect(leased.hasOpenSession, isFalse, reason: 'no session before first use');

          // A read opens a session on demand...
          final v = await leased.read(PlcFixture.counterName);
          expect(v.asInt, isNotNull);
          expect(leased.hasOpenSession, isTrue);
          if (base != null) {
            expect(await observer.currentSessionCount(), greaterThan(base));
          }

          // ...and after the idle window the session is released.
          await _eventually(() async => !leased.hasOpenSession, const Duration(seconds: 3));
          expect(leased.hasOpenSession, isFalse, reason: 'idle session must be released');
          if (base != null) {
            await _eventually(() async => (await observer.currentSessionCount()) == base, const Duration(seconds: 3));
            expect(await observer.currentSessionCount(), base, reason: 'idle leased client must add 0 sessions');
          }

          // A later read transparently reconnects.
          final again = await leased.read(PlcFixture.counterName);
          expect(again.asInt, isNotNull);
        } finally {
          await leased.dispose();
        }
      });

      test('session budget guard fails loud before over-opening', () async {
        // Emulator-only: deliberately reaching the cap on real hardware is
        // exactly what we are trying to avoid.
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
      }, skip: cfg.useEmulator ? false : 'budget-cap test is emulator-only (would stress real hardware)');
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
