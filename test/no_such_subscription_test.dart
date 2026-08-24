// Regression test for PR #37 ("No such subscription").
//
// Monitoring a node against a subscription id that does not exist on the
// server must surface an error on the monitor stream (BadSubscriptionIdInvalid)
// instead of corrupting native memory (the original report was a double free).

import 'dart:async';
import 'dart:math';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';

final intNodeId = NodeId.fromString(1, "the.int");

void main() {
  final rng = Random();
  final serverPort = 14840 + rng.nextInt(1000);

  late Server server;
  late Client client;
  late Timer serverTimer;
  Timer? clientTimer;

  setUp(() async {
    server = Server(port: serverPort, logLevel: LogLevel.UA_LOGLEVEL_WARNING);
    server.start();

    DynamicValue intValue = DynamicValue(value: 0, typeId: NodeId.int32, name: "the.int");
    server.addVariableNode(intNodeId, intValue);

    serverTimer = Timer.periodic(Duration(milliseconds: 10), (_) {
      server.runIterate();
    });

    client = Client(logLevel: LogLevel.UA_LOGLEVEL_WARNING);

    clientTimer = Timer.periodic(Duration(milliseconds: 10), (_) {
      client.runIterate(Duration(milliseconds: 10));
    });

    await client.connect("opc.tcp://127.0.0.1:$serverPort");
  });

  tearDown(() async {
    clientTimer?.cancel();
    serverTimer.cancel();
    server.shutdown();
    await client.delete();
    server.delete();
  });

  test('monitoring a non-existent subscription surfaces an error, no crash', () async {
    // 99999 was never returned by subscriptionCreate → does not exist server-side.
    final stream = client.monitor(intNodeId, 99999, samplingInterval: Duration(milliseconds: 10));

    final errorCompleter = Completer<Object>();
    final sub = stream.listen(
      (event) {},
      onError: (error) {
        if (!errorCompleter.isCompleted) errorCompleter.complete(error);
      },
    );

    final error = await errorCompleter.future.timeout(
      Duration(seconds: 10),
      onTimeout: () => fail('Expected an error for a non-existent subscription'),
    );
    print('Got expected error: $error');

    await sub.cancel();

    // Let a few more iterate cycles run to shake out any deferred double-free.
    await Future.delayed(Duration(milliseconds: 500));
  }, timeout: Timeout(Duration(seconds: 30)));
}
