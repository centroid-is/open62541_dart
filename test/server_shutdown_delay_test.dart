import 'dart:async';
import 'dart:isolate';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'common.dart';

/// Orderly shutdown: `Server.shutdown(delay:)` announces the shutdown through
/// `ServerStatus.State` = Shutdown and a `SecondsTillShutdown` countdown (the
/// Part 5 §12.6 hand-off signal), keeps serving for the delay, then shuts
/// down. The call blocks the server's isolate for the delay, so the server
/// lives on a spawned isolate and the observing `Client` on the test's.
final stateId = NodeId.serverStatusState;
final secondsTillShutdownId = NodeId.fromNumeric(0, raw.UA_NS0ID_SERVER_SERVERSTATUS_SECONDSTILLSHUTDOWN);
final theInt = NodeId.fromString(1, 'the.int');

const serverStateRunning = 0;
const serverStateShutdown = 4;
const delay = Duration(seconds: 3);

/// A server on its own isolate. Reports `['port', port, control]`, pumps
/// until anything arrives on `control`, then shuts down the way [mode] says
/// ('arg': `shutdown(delay:)`, 'config': `shutdownDelay` then `shutdown()`,
/// 'plain': `shutdown()`) and reports `['stopped', millisecondsBlocked]`.
void _serverIsolate(List<Object> args) {
  final reply = args[0] as SendPort;
  final mode = args[1] as String;

  final server = Server(port: 0, logLevel: LogLevel.UA_LOGLEVEL_ERROR);
  server.addVariableNode(theInt, DynamicValue(name: 'the.int', value: 42, typeId: NodeId.int32));
  server.start();

  final control = ReceivePort();
  var go = false;
  control.first.then((_) => go = true);
  () async {
    while (!go) {
      server.runIterate();
      await Future.delayed(const Duration(milliseconds: 20));
    }
    final clock = Stopwatch()..start();
    switch (mode) {
      case 'arg':
        server.shutdown(delay: delay);
      case 'config':
        server.shutdownDelay = delay;
        server.shutdown();
      default:
        server.shutdown();
    }
    final blocked = clock.elapsedMilliseconds;
    server.delete();
    reply.send(['stopped', blocked]);
  }();
  reply.send(['port', server.port, control.sendPort]);
}

void main() {
  late ReceivePort reply;
  late StreamIterator<dynamic> messages;
  late SendPort control;
  late Client client;

  Future<void> spawn(String mode) async {
    reply = ReceivePort();
    messages = StreamIterator(reply);
    await Isolate.spawn(_serverIsolate, <Object>[reply.sendPort, mode]);
    expect(await messages.moveNext(), isTrue);
    final [_, int port, SendPort port_] = messages.current as List;
    control = port_;
    client = await setupClient(port);
  }

  Future<int> stopped() async {
    expect(await messages.moveNext(), isTrue);
    final [_, int blocked] = messages.current as List;
    return blocked;
  }

  group('shutdown(delay:)', () {
    tearDown(() async {
      await client.delete();
      reply.close();
    });

    test('during the delay a client reads State == Shutdown, a countdown, and data as before', () async {
      await spawn('arg');
      expect((await client.read(stateId)).asInt, serverStateRunning);
      expect((await client.read(secondsTillShutdownId)).asInt, 0);

      control.send('go');
      await Future.delayed(const Duration(milliseconds: 300));

      // The hand-off signal.
      expect((await client.read(stateId)).asInt, serverStateShutdown);
      final secondsLeft = (await client.read(secondsTillShutdownId)).asInt!;
      expect(secondsLeft, inInclusiveRange(1, delay.inSeconds));
      // The server is still a server: the session lives and data reads are Good.
      final data = await client.readValue(theInt);
      expect(data.isGood, isTrue);
      expect(data.value.asInt, 42);
      // And the clock runs.
      await Future.delayed(const Duration(milliseconds: 1100));
      expect((await client.read(secondsTillShutdownId)).asInt, lessThan(secondsLeft));

      // Then the server goes away, having blocked its isolate for the delay.
      final blocked = await stopped();
      expect(blocked, greaterThanOrEqualTo(delay.inMilliseconds));
      expect(blocked, lessThan(delay.inMilliseconds + 1500));
      await expectLater(client.read(theInt), throwsA(anything));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('a shutdownDelay set beforehand is honoured by shutdown()', () async {
      await spawn('config');
      control.send('go');
      await Future.delayed(const Duration(milliseconds: 300));
      expect((await client.read(stateId)).asInt, serverStateShutdown);
      expect((await client.read(secondsTillShutdownId)).asInt, greaterThan(0));
      expect(await stopped(), greaterThanOrEqualTo(delay.inMilliseconds));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('shutdown() without a delay is immediate, as before', () async {
      await spawn('plain');
      control.send('go');
      // Nothing to observe: the server is gone before a read could see a
      // Shutdown state, and the isolate was not held.
      expect(await stopped(), lessThan(1000));
      await expectLater(client.read(stateId), throwsA(anything));
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  group('shutdownDelay', () {
    test('defaults to zero, round-trips through the config, refuses a negative value', () {
      final server = Server(port: 0);
      try {
        expect(server.shutdownDelay, Duration.zero);
        server.shutdownDelay = const Duration(milliseconds: 1500);
        expect(server.shutdownDelay, const Duration(milliseconds: 1500));
        expect(() => server.shutdownDelay = const Duration(seconds: -1), throwsArgumentError);
        expect(server.shutdownDelay, const Duration(milliseconds: 1500));
        server.shutdownDelay = Duration.zero;
        expect(server.shutdownDelay, Duration.zero);
      } finally {
        server.delete();
      }
    });

    test('a delay on a server that was never started does not stall: shutdown() fails fast as before', () {
      final server = Server(port: 0);
      try {
        final clock = Stopwatch()..start();
        expect(() => server.shutdown(delay: delay), throwsA(anything));
        expect(clock.elapsedMilliseconds, lessThan(1000));
      } finally {
        server.delete();
      }
    });
  });
}
