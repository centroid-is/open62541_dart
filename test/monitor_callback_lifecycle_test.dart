// Tests for monitor callback lifecycle bugs:
//
// 1. Race condition: cancelling a monitored items stream closes the
//    monitorCallback in the delete-response handler. If a Publish response
//    arrives in the same runIterate batch *after* the delete response,
//    the native code invokes the freed callback → VM crash:
//    "Callback invoked after it has been deleted."
//
// 2. Double-close: the sync error path in monitoredItems() previously
//    called monitorCallback.close() and ua_calloc.free(callbacks) twice.

import 'dart:async';
import 'dart:math';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';

final intNodeId = NodeId.fromString(1, "the.int");

void main() {
  final rng = Random();
  final serverPort = 16840 + rng.nextInt(1000);

  late Server server;
  late Client client;
  late Timer serverTimer;
  Timer? clientTimer;

  setUp(() async {
    server = Server(port: serverPort, logLevel: LogLevel.UA_LOGLEVEL_WARNING);
    server.start();

    DynamicValue intValue =
        DynamicValue(value: 42, typeId: NodeId.int32, name: "the.int");
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

  // ---------------------------------------------------------------
  // Test 1: Cancel-then-publish race condition
  //
  // The stream cancel queues UA_Client_MonitoredItems_delete_async.
  // The delete response handler used to immediately close monitorCallback.
  // If the server sends a Publish response in the same runIterate batch,
  // processPublishResponseAsync tries to invoke the closed NativeCallable.
  //
  // Strategy:
  //   a) Create subscription + monitored item, confirm data flows.
  //   b) Pause the client event loop (stop runIterate).
  //   c) Cancel the stream subscription → queues delete request.
  //   d) Server continues publishing — responses queue on TCP socket.
  //   e) Resume runIterate. All queued responses processed in one batch.
  //   f) Before the fix, this could crash. After the fix, it must not.
  // ---------------------------------------------------------------
  test(
      'cancel-then-publish: monitorCallback must survive until runIterate batch completes',
      () async {
    final subscriptionId = await client.subscriptionCreate(
      requestedPublishingInterval: Duration(milliseconds: 50),
    );

    final stream = client.monitor(
      intNodeId,
      subscriptionId,
      samplingInterval: Duration(milliseconds: 50),
    );

    final values = <DynamicValue>[];
    final sub = stream.listen((v) => values.add(v));

    // Wait for data to flow
    await Future.delayed(Duration(milliseconds: 500));
    expect(values, isNotEmpty, reason: 'Should have received initial data');

    // === Pause client so requests/responses queue up ===
    clientTimer?.cancel();
    clientTimer = null;

    // Cancel the stream while the client is paused.
    // This queues UA_Client_MonitoredItems_delete_async internally
    // but the delete request won't be sent until runIterate runs.
    unawaited(sub.cancel());

    // Let the server keep publishing for a bit — these Publish responses
    // will stack up on the TCP socket alongside the delete response.
    await Future.delayed(Duration(milliseconds: 300));

    // === Resume client: process all queued responses in one burst ===
    // Before the fix, this could crash the Dart VM with:
    //   "Callback invoked after it has been deleted"
    clientTimer = Timer.periodic(Duration(milliseconds: 10), (_) {
      client.runIterate(Duration(milliseconds: 10));
    });

    // Give the client time to process everything.
    // If we get here without a crash, the fix works.
    await Future.delayed(Duration(milliseconds: 500));

    // Verify we can still use the client (it didn't crash or corrupt state).
    final readValue = await client.read(intNodeId);
    expect(readValue.value, equals(42));
  }, timeout: Timeout(Duration(seconds: 15)));

  // ---------------------------------------------------------------
  // Test 2: Rapid cancel-and-resubscribe cycle
  //
  // Reproduces the production scenario: StateMan's _monitor retry loop
  // cancels the old raw subscription and immediately creates a new one.
  // The old delete is async; new creation happens before old delete
  // response arrives.
  //
  // Each iteration creates a fresh subscription to avoid server-side
  // subscription expiry from accumulated cancel/resubscribe churn.
  // ---------------------------------------------------------------
  test('rapid cancel-resubscribe: old callback survives until native cleanup',
      () async {
    for (var i = 0; i < 5; i++) {
      final subscriptionId = await client.subscriptionCreate(
        requestedPublishingInterval: Duration(milliseconds: 50),
      );

      final stream = client.monitor(
        intNodeId,
        subscriptionId,
        samplingInterval: Duration(milliseconds: 50),
      );

      final values = <DynamicValue>[];
      final sub = stream.listen((v) => values.add(v));

      // Wait for data to flow
      await Future.delayed(Duration(milliseconds: 500));
      expect(values, isNotEmpty,
          reason: 'Iteration $i: should receive data');

      // Cancel fire-and-forget (like StateMan does)
      unawaited(sub.cancel());

      // Small delay for the delete to be queued
      await Future.delayed(Duration(milliseconds: 100));
    }

    // Verify client is still healthy after all the cycling
    final readValue = await client.read(intNodeId);
    expect(readValue.value, equals(42));
  }, timeout: Timeout(Duration(seconds: 30)));
}
