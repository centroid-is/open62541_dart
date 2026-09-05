import 'dart:async';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart';

/// A [Client] has historically needed an isolate of its own because its pump
/// blocks: `runIterate(d)` sits in open62541's `select()` for up to `d`. These
/// tests pin the property that makes the isolate unnecessary — a zero timeout
/// is a real non-blocking poll — and that a client driven that way works
/// end-to-end while sharing an isolate with the code consuming its data.
void main() {
  late Server server;
  late int port;

  setUp(() async {
    port = await freeTcpPort();
    server = setupServer(port);
    addBasicVariables(server);
  });

  tearDown(() async {
    server.shutdown();
    await Future.delayed(const Duration(milliseconds: 100));
    server.delete();
  });

  test('runIterate(Duration.zero) does not block, a non-zero timeout does', () async {
    final client = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
    // Connect with a non-blocking pump so the client has a live, idle socket
    // registered with the event loop — otherwise the loop has no FDs to wait on
    // and would return immediately regardless of the timeout.
    var pumping = true;
    () async {
      while (pumping) {
        client.runIterate(Duration.zero);
        await Future.delayed(const Duration(milliseconds: 1));
      }
    }();
    await client.connect('opc.tcp://localhost:$port');
    pumping = false;
    await Future.delayed(const Duration(milliseconds: 20));

    // Nothing is subscribed, so no traffic is inbound and the timeout is what
    // decides how long each call takes.
    final poll = Stopwatch()..start();
    for (var i = 0; i < 10; i++) {
      client.runIterate(Duration.zero);
    }
    poll.stop();

    final block = Stopwatch()..start();
    client.runIterate(const Duration(milliseconds: 300));
    block.stop();

    expect(poll.elapsedMilliseconds, lessThan(50), reason: 'ten zero-timeout iterations should be a poll, not a wait');
    expect(block.elapsedMilliseconds, greaterThan(150), reason: 'a 300ms timeout must actually wait on an idle socket');

    client.delete();
  });

  test('keepConnected(nonBlocking: true) delivers values without blocking its isolate', () async {
    final client = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
    await client.keepConnected(
      'opc.tcp://localhost:$port',
      nonBlocking: true,
      iterateInterval: const Duration(milliseconds: 1),
    );

    final sub = await client.subscriptionCreate(requestedPublishingInterval: const Duration(milliseconds: 20));
    final seen = <int>[];
    final monitor = client
        .monitor(intNodeId, sub, samplingInterval: const Duration(milliseconds: 0), queueSize: 10)
        .listen((v) => seen.add(v.asInt));

    // Metronome on the SAME isolate: if the pump blocked, these ticks would be
    // starved. The bound is deliberately generous so it holds on loaded CI.
    const beat = Duration(milliseconds: 5);
    var ticks = 0;
    final metronome = Timer.periodic(beat, (_) => ticks++);

    for (var i = 1; i <= 40; i++) {
      server.write(intNodeId, DynamicValue(value: i, typeId: NodeId.int32));
      await Future.delayed(const Duration(milliseconds: 20));
    }
    await Future.delayed(const Duration(milliseconds: 300));
    metronome.cancel();
    await monitor.cancel();

    expect(seen, isNotEmpty, reason: 'a non-blocking pump must still deliver notifications');
    expect(seen.last, greaterThan(30), reason: 'delivery should keep up with the writes');
    // ~220 beats are due over the ~1.1s run; a blocking 10ms pump would eat
    // most of them.
    expect(ticks, greaterThan(100), reason: 'the pump must leave the isolate free to run its own timers');

    client.stopKeepConnected();
    client.delete();
  });
}
