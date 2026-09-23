// Regression tests for the Client.write() native-callback leak.
//
// write() creates one NativeCallable per request and used to close it only on
// the success path, after `completer.complete()`. A write the server rejected
// (a node answering Bad_NotWritable — routine on a plant), a bad service
// result, or a request that never got a callback at all each leaked a native
// trampoline, and with it the closure and the variant it captured.
//
// A live NativeCallable.isolateLocal keeps its isolate alive, so the leak has
// a directly observable consequence: an isolate that performed a rejected
// write and then deleted its client could never exit. That is what the first
// test pins — it needs no VM-service introspection, only Isolate.onExit.

import 'dart:async';
import 'dart:isolate';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart';

final gatedNodeId = NodeId.fromString(1, 'datasource.gated');

/// Runs in its own isolate: connect, perform one rejected write, tear the
/// client down, report the rejection, return. With nothing leaked the isolate
/// then exits on its own.
Future<void> rejectedWriteThenReturn((int, SendPort) args) async {
  final (port, report) = args;
  final client = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
  final pump = Timer.periodic(Duration(milliseconds: 5), (_) {
    client.runIterate(Duration(milliseconds: 5));
  });
  await client.connect('opc.tcp://127.0.0.1:$port');

  Object? rejection;
  try {
    await client.write(gatedNodeId, DynamicValue(value: 11, typeId: NodeId.int32));
  } catch (e) {
    rejection = e;
  }

  pump.cancel();
  await client.delete();
  report.send(rejection is UaStatusException ? rejection.statusCode : rejection.toString());
}

void main() {
  late int port;
  late Server server;

  setUp(() async {
    port = await freeTcpPort();
    server = setupServer(port);
    server.addDataSourceVariableNode(
      gatedNodeId,
      browseName: 'Gated',
      typeId: NodeId.int32,
      onRead: () => DynamicValue(name: 'Gated', value: 10, typeId: NodeId.int32),
      // Advertises Write access, refuses every write: the shape a plant logs
      // as Bad_NotWritable all day.
      onWrite: (_) async => throw const UaStatusException(UA_STATUSCODE_BADNOTWRITABLE),
    );
  });

  tearDown(() {
    server.shutdown();
    server.delete();
  });

  test('a rejected write releases its native callback: the isolate can exit', () async {
    final report = ReceivePort();
    final exited = ReceivePort();
    await Isolate.spawn(rejectedWriteThenReturn, (port, report.sendPort), onExit: exited.sendPort);

    final rejection = await report.first.timeout(Duration(seconds: 10));
    expect(rejection, UA_STATUSCODE_BADNOTWRITABLE, reason: 'the write must be rejected with the typed status');

    // Before the fix the leaked NativeCallable kept the isolate alive forever.
    await exited.first.timeout(
      Duration(seconds: 10),
      onTimeout: () => fail('the isolate never exited: a NativeCallable is still open after the rejected write'),
    );
  }, timeout: Timeout(Duration(seconds: 30)));

  test('a write on a dead connection fails typed instead of hanging', () async {
    final client = await setupClient(port);
    // Drop the server; wait until the client has noticed the channel is gone.
    server.shutdown();
    server.delete();
    await Future.delayed(Duration(milliseconds: 500));
    server = setupServer(await freeTcpPort()); // for tearDown

    // open62541 refuses to send on a closed channel synchronously and never
    // invokes the callback. write() used to ignore that status: the future
    // never completed and the callback (and variant) leaked.
    await expectLater(
      client.write(gatedNodeId, DynamicValue(value: 1, typeId: NodeId.int32)).timeout(
        Duration(seconds: 3),
        onTimeout: () => fail('write() never completed on a dead connection'),
      ),
      throwsA(isA<UaStatusException>().having((e) => e.statusCode, 'statusCode', UA_STATUSCODE_BADSERVERNOTCONNECTED)),
    );
    await client.delete();
  }, timeout: Timeout(Duration(seconds: 15)));
}
