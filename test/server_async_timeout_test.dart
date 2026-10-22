// `Server.asyncOperationTimeout`: the deadline open62541 gives a parked async
// operation (a method call or a data-source write whose handler has not
// completed) before cancelling it with Bad_Timeout.
//
// `UA_ServerConfig_setMinimal` sets the 2-minute default only under
// `UA_MULTITHREADING >= 100`; this package builds single-threaded, so the
// field came out 0 ("never"), and a handler that never completed left its
// operation, its output memory and the client's request in flight forever.
// The constructor now sets the 2 minutes the dartdoc always promised.

import 'dart:async';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'common.dart';

void main() {
  test('a fresh Server has a 2-minute asyncOperationTimeout', () {
    final server = Server(port: 0, logLevel: LogLevel.UA_LOGLEVEL_FATAL);
    addTearDown(server.delete);

    expect(server.asyncOperationTimeout, const Duration(minutes: 2));
  });

  for (final clientType in clientTypes) {
    group('[$clientType]', () {
      late Server server;
      late ClientApi client;
      final parkedNodeId = NodeId.fromString(1, 'async.parked');
      final plainNodeId = NodeId.fromString(1, 'async.plain');

      setUp(() async {
        server = setupServer();
        server.addDataSourceVariableNode(
          parkedNodeId,
          browseName: 'async.parked',
          typeId: NodeId.int32,
          onRead: () => DynamicValue(value: 1, typeId: NodeId.int32),
          // A device that never answers: the handler's future never completes.
          onWrite: (_) => Completer<void>().future,
        );
        server.addVariableNode(plainNodeId, DynamicValue(value: 5, typeId: NodeId.int32, name: 'async.plain'));
        client = await setupClientOfType(clientType, 'opc.tcp://127.0.0.1:${server.port}');
      });

      tearDown(() async {
        await client.delete();
        server.shutdown();
        server.delete();
      });

      test('a parked write is cancelled with Bad_Timeout once asyncOperationTimeout passes', () async {
        // open62541 checks the deadlines once a second, so a 1 s timeout is
        // reported within about 2 s. The client's own request timeout is
        // 5 s and would also surface as Bad_Timeout, so the elapsed time is
        // what tells the server's cancellation from the client giving up.
        server.asyncOperationTimeout = const Duration(seconds: 1);
        final started = DateTime.now();

        await expectLater(
          client.write(parkedNodeId, DynamicValue(value: 2, typeId: NodeId.int32)),
          throwsA(isA<UaStatusException>().having((e) => e.statusCode, 'statusCode', raw.UA_STATUSCODE_BADTIMEOUT)),
        );

        final elapsed = DateTime.now().difference(started);
        expect(
          elapsed,
          lessThan(const Duration(seconds: 4)),
          reason: 'the server must cancel the operation at its deadline, not the client at its 5 s request timeout',
        );
        // The server is intact after the cancellation.
        expect((await client.read(plainNodeId)).asInt, 5);
      });
    });
  }
}
