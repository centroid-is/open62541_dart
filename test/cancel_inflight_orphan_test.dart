// Regression test for the "orphaned monitored item" leak (stale-keys bug).
//
// monitoredItems() sends CreateMonitoredItems the moment it is listened to.
// If the stream is cancelled before the response is processed, monitorTeardown
// takes the monIds-empty path: UA_Client_cancelByRequestId. The OPC UA Cancel
// service only cancels requests the server has not started processing —
// open62541's server (and TwinCAT in the plant) has usually already created
// the items by then, and answers the original request with GOOD. The old
// binding never followed up, so the server-side monitored item was left
// sampling and publishing forever: the client either forgot it (open62541
// logs "Could not process a notification with clienthandle N" for every
// publish) or silently buffered its data into a cancelled controller.
//
// This test observes the ground truth on the server side: a data-source
// variable node counts every sampling read. After cancelling a mid-flight
// create, the server must stop sampling the node — i.e. the binding must
// deliver a real DeleteMonitoredItems once the create response reveals the
// monitoredItemIds.
//
// The server runs in a separate isolate so it keeps responding while the
// client-side teardown performs its synchronous CancelRequest.
@Timeout(Duration(seconds: 120))
library;

import 'dart:async';
import 'dart:isolate';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';

import 'common.dart' show freeTcpPort;

final sampledNodeId = NodeId.fromString(1, 'the.sampled');

/// Server isolate entry point: hosts one Server with a data-source variable
/// whose read callback reports every invocation to the main isolate.
void serverMain(List<Object?> args) {
  final sendPort = args[0] as SendPort;
  final port = args[1] as int;

  final server = Server(port: port, logLevel: LogLevel.UA_LOGLEVEL_ERROR);
  server.start();

  var reads = 0;
  server.addDataSourceVariableNode(
    sampledNodeId,
    browseName: 'the.sampled',
    typeId: NodeId.int32,
    onRead: () {
      reads++;
      sendPort.send(reads);
      return DynamicValue(value: reads, typeId: NodeId.int32);
    },
  );

  final control = ReceivePort();
  sendPort.send(control.sendPort);
  var running = true;
  control.listen((msg) {
    if (msg == 'shutdown') running = false;
  });

  () async {
    while (running && server.runIterate()) {
      await Future.delayed(const Duration(milliseconds: 10));
    }
    server.shutdown();
    server.delete();
    control.close();
  }();
}

void main() {
  test('cancelling a mid-flight CreateMonitoredItems deletes the item on the server', () async {
    final port = await freeTcpPort();

    final fromServer = ReceivePort();
    final controlReady = Completer<SendPort>();
    var readCount = 0;
    fromServer.listen((msg) {
      if (msg is SendPort) {
        controlReady.complete(msg);
        return;
      }
      readCount = msg as int;
    });
    final serverIsolate = await Isolate.spawn(serverMain, <Object?>[fromServer.sendPort, port]);
    final serverControl = await controlReady.future.timeout(const Duration(seconds: 20));

    final client = Client(logLevel: LogLevel.UA_LOGLEVEL_WARNING);
    final pump = Timer.periodic(const Duration(milliseconds: 10), (_) {
      client.runIterate(const Duration(milliseconds: 5));
    });

    try {
      await client.connect('opc.tcp://127.0.0.1:$port');
      final subId = await client.subscriptionCreate();

      // --- the race under test -------------------------------------------
      // listen() sends CreateMonitoredItems synchronously; cancelling in the
      // same synchronous turn guarantees the client has not processed the
      // response yet, so teardown takes the cancel-by-request-id path while
      // the server (separate isolate) has already created the item.
      final stream = client.monitoredItems(
        {
          sampledNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE],
        },
        subId,
        samplingInterval: const Duration(milliseconds: 50),
      );
      final sub = stream.listen((_) {});
      final cancelDone = sub.cancel(); // same turn: create still in flight
      await cancelDone;

      // Sanity: the server really did create + sample the item at least once
      // (the cancel did not beat the create to the server).
      final sawSampling = DateTime.now().add(const Duration(seconds: 5));
      while (readCount == 0 && DateTime.now().isBefore(sawSampling)) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      expect(
        readCount,
        greaterThan(0),
        reason:
            'precondition: the server should have created and sampled '
            'the monitored item before the cancel could take effect',
      );

      // Grace period for the (fixed) binding to learn the monitoredItemIds
      // from the create response and deliver DeleteMonitoredItems.
      await Future.delayed(const Duration(seconds: 3));

      // Ground truth: is the server still sampling the node?
      final before = readCount;
      await Future.delayed(const Duration(seconds: 2));
      final after = readCount;

      expect(
        after - before,
        0,
        reason:
            'server kept sampling the node ($before -> $after reads in 2s): '
            'the monitored item created by the cancelled request was never '
            'deleted on the server — it is an orphan that publishes forever',
      );
    } finally {
      pump.cancel();
      serverControl.send('shutdown');
      await Future.delayed(const Duration(milliseconds: 100));
      fromServer.close();
      await client.delete();
      serverIsolate.kill(priority: Isolate.immediate);
    }
  });
}
