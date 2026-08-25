import 'dart:async';
import 'dart:math';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart';

// The plant failure this exists for (tfc-hmi #345/#346, bench 2026-08-25):
// against secured (SignAndEncrypt) servers, a dead connection can wedge the
// client isolate inside a native call. From the outside the isolate simply
// stops answering: state queries time out, monitored items go silent, and --
// decisive -- Disconnect/anything-else sent to the isolate is never processed,
// so no supervisor that works THROUGH the isolate can recover it. The only
// recovery is to abandon the wedged isolate and spawn a fresh one.
//
// keepConnected is the supervisor, so it owns this too: it pings the isolate,
// and when the isolate stops answering it respawns it and re-arms itself.
// Streams survive as objects (stateStream keeps emitting from the new
// isolate; monitored-item streams error so callers resubscribe).

int _randomPort() => Random().nextInt(10000) + 24840;

Future<bool> _waitFor(Future<bool> Function() cond, Duration timeout) async {
  final sw = Stopwatch()..start();
  while (sw.elapsed < timeout) {
    if (await cond()) return true;
    await Future.delayed(const Duration(milliseconds: 100));
  }
  return false;
}

void main() {
  test('a wedged isolate is respawned and the client recovers on its own', () async {
    final port = _randomPort();
    final server = Server(port: port, logLevel: LogLevel.UA_LOGLEVEL_ERROR);
    server.start();
    addBasicVariables(server);
    final pump = Timer.periodic(const Duration(milliseconds: 20), (_) => server.runIterate());

    final client = await ClientIsolate.create(logLevel: LogLevel.UA_LOGLEVEL_ERROR);
    addTearDown(() async {
      try {
        await client.delete().timeout(const Duration(seconds: 5));
      } catch (_) {}
      pump.cancel();
      try {
        server.shutdown();
      } catch (_) {}
      server.delete();
    });

    // States observed across the WHOLE test through one listener,
    // subscribed before the wedge: the stream object must survive respawn.
    final activations = <DateTime>[];
    client.stateStream.listen((s) {
      if (s.sessionState == SessionState.UA_SESSIONSTATE_ACTIVATED) {
        activations.add(DateTime.now());
      }
    });

    await client.keepConnected('opc.tcp://127.0.0.1:$port', unresponsiveTimeout: const Duration(seconds: 2));
    expect((await client.read(intNodeId)).asInt, 1, reason: 'sanity: connected and reading before the wedge');

    // Wedge the isolate the way the dead-socket FFI call does: its event
    // loop blocks, and every message from the main side goes unanswered.
    client.debugWedgeIsolate(const Duration(seconds: 3600));

    // The wedge is real: a state query now times out.
    await expectLater(
      client.state.timeout(const Duration(seconds: 1)),
      throwsA(isA<TimeoutException>()),
      reason: 'precondition: the isolate must actually be unresponsive',
    );

    final wedgedAt = DateTime.now();

    // Self-heal: within a few unresponsiveTimeouts the supervisor must
    // notice, respawn, reconnect, and answer again.
    final healed = await _waitFor(() async {
      try {
        final s = await client.state.timeout(const Duration(seconds: 1));
        return s.sessionState == SessionState.UA_SESSIONSTATE_ACTIVATED;
      } catch (_) {
        return false;
      }
    }, const Duration(seconds: 30));
    expect(
      healed,
      isTrue,
      reason:
          'the supervisor must abandon the wedged isolate, respawn, '
          'and reconnect without any action from the caller',
    );

    // And it is a REAL session: reads work again.
    expect((await client.read(intNodeId)).asInt, 1, reason: 'values must flow again after self-heal');

    // The state stream the caller subscribed BEFORE the wedge saw the
    // post-respawn activation: stream objects survive the respawn.
    expect(
      activations.where((t) => t.isAfter(wedgedAt)),
      isNotEmpty,
      reason:
          'stateStream must keep emitting from the respawned isolate '
          '-- callers subscribe once at construction and never again',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));
}
