import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart' show freeTcpPort;
import 'heap_growth.dart';

/// Regression tests for native memory a [Client] allocated and never freed.
/// Each repeats one operation that must leave the C heap as it found it, see
/// heap_growth.dart.
void main() {
  test('a client with a username and password leaves nothing on the C heap once deleted', () async {
    // Long credentials, so that the two strings stand out against the rest of
    // a client's life: delete() takes 10 ms, which leaves few clients per round.
    final username = 'u' * 2000;
    final password = 'p' * 3000;
    await expectNoHeapGrowth(
      () => Client(username: username, password: password, logLevel: LogLevel.UA_LOGLEVEL_FATAL).delete(),
      warmUp: 20,
      iterations: 10,
      rounds: 7,
      maxGrowth: 1000,
      attempts: 3,
    );
  });

  group('connected:', () {
    late Server server;
    late Client client;
    late String url;

    final variableId = NodeId.fromString(1, 'leak.test.variable.${'v' * 100}');

    /// Drives both event loops until [future] completes. Nothing else pumps
    /// them: a timer-driven loop would stretch every round trip to milliseconds.
    Future<T> pump<T>(Future<T> future) async {
      var done = false;
      future.whenComplete(() => done = true).ignore();
      while (!done) {
        server.runIterate();
        client.runIterate(Duration.zero);
        await Future<void>.delayed(Duration.zero);
      }
      return future;
    }

    setUpAll(() async {
      final port = await freeTcpPort();
      server = Server(port: port, logLevel: LogLevel.UA_LOGLEVEL_FATAL);
      server.start();
      server.addVariableNode(variableId, DynamicValue(value: 0, typeId: NodeId.int32, name: 'variable'));

      url = 'opc.tcp://127.0.0.1:$port';
      client = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
      await pump(client.connect(url));
    });

    tearDownAll(() async {
      // The server goes first, and the client gets to see its channel close.
      // Deleting a client whose session is still active waits five seconds
      // for a CloseSession answer that a server pumped by this very isolate
      // cannot give meanwhile.
      server.shutdown();
      for (var i = 0; i < 10; i++) {
        client.runIterate(Duration.zero);
      }
      await client.delete();
      server.delete();
    });

    test('connecting leaves nothing on the C heap', () async {
      // open62541 takes its own copy of the URL on every connect call, also on
      // one that finds the client connected already, which is the cheap way to
      // repeat it: the session stays as it is.
      await expectNoHeapGrowth(() => client.connect(url), warmUp: 2000, iterations: 1000, rounds: 9);
      expect((await pump(client.read(variableId))).asInt, 0, reason: 'the session must have survived');
    });
  });
}
