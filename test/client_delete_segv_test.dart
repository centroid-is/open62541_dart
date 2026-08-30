// Regression test for a High-severity use-after-free / VM-crash bug.
//
// Symptom
//   Client.delete() on the DIRECT client tears down the native client while
//   monitored-item streams are still active. An in-flight Publish data-change
//   notification (or a native state callback) is then delivered against the
//   freed native client, which crashed the Dart VM (SEGV / SEGV_ACCERR) in the
//   reporter's harness. Even where it does not hard-crash, the still-registered
//   config-stream listeners deliver error events (SecureChannelClosed /
//   SubscriptionDeleted) into the active monitor streams as the client is
//   force-deleted underneath them.
//
// Root cause
//   lib/src/client.dart Client.delete() called raw.UA_Client_delete(client)
//   WITHOUT first cancelling active monitored-item streams. There was no central
//   registry of active streams, so delete() could not tear them down first.
//
// Why the isolate client was already safe
//   lib/src/isolate.dart DeleteMessage handler cancels every active stream
//   (for (final s in activeStreams.values) await s.cancel();) before calling
//   client.delete(). The fix mirrors that ordering for the direct client via a
//   _activeMonitoredStreams registry drained at the top of delete(): every
//   active stream's native monitored items are deleted and its NativeCallables
//   closed BEFORE UA_Client_delete frees the client.
//
// What this test asserts
//   For each case we start a server with a variable, connect a client, create a
//   subscription, start a monitor()/monitoredItems() stream, wait until data is
//   flowing, then call client.delete() WITHOUT cancelling the stream.
//   Post-fix (cancel-before-delete):
//     * the VM stays alive — a follow-up async await + expect runs, and
//     * no error events are delivered into the still-active streams, because
//       delete() cancelled them (and their config-stream error listeners)
//       before freeing the client.
//   Pre-fix (delete-before-cancel):
//     * the process crashes (SEGV) OR, where it survives, error events are
//       delivered into the active streams — either way this test FAILS.

import 'dart:async';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';

import 'common.dart' show freeTcpPort;

final intNodeId = NodeId.fromString(1, "the.int");
final int2NodeId = NodeId.fromString(1, "the.int2");
final int3NodeId = NodeId.fromString(1, "the.int3");

void main() {
  late int serverPort;

  late Server server;
  late Client client;
  Timer? serverTimer;
  Timer? clientTimer;
  Timer? churnTimer;

  Future<void> setup() async {
    serverPort = await freeTcpPort();
    server = Server(port: serverPort, logLevel: LogLevel.UA_LOGLEVEL_ERROR);
    server.start();

    server.addVariableNode(intNodeId, DynamicValue(value: 0, typeId: NodeId.int32, name: "the.int"));
    server.addVariableNode(int2NodeId, DynamicValue(value: 0, typeId: NodeId.int32, name: "the.int2"));
    server.addVariableNode(int3NodeId, DynamicValue(value: 0, typeId: NodeId.int32, name: "the.int3"));

    // Drive the server event loop (mirrors test/common.dart setupServer).
    serverTimer = Timer.periodic(Duration(milliseconds: 10), (_) {
      server.runIterate();
    });

    // Continuously mutate the variables so Publish data-change notifications are
    // always in flight — this maximises the chance of an in-flight notification
    // at delete time, which is what triggers the use-after-free on the unpatched
    // client.
    var counter = 0;
    churnTimer = Timer.periodic(Duration(milliseconds: 10), (_) {
      counter++;
      server.write(intNodeId, DynamicValue(value: counter, typeId: NodeId.int32, name: "the.int"));
      server.write(int2NodeId, DynamicValue(value: counter, typeId: NodeId.int32, name: "the.int2"));
      server.write(int3NodeId, DynamicValue(value: counter, typeId: NodeId.int32, name: "the.int3"));
    });

    client = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL);

    // Drive the client event loop (mirrors test/common.dart setupClient).
    clientTimer = Timer.periodic(Duration(milliseconds: 10), (_) {
      client.runIterate(Duration(milliseconds: 10));
    });

    await client.connect("opc.tcp://127.0.0.1:$serverPort");
  }

  void teardown() {
    churnTimer?.cancel();
    clientTimer?.cancel();
    serverTimer?.cancel();
    server.shutdown();
    server.delete();
  }

  test('delete() with a single active monitored-item stream: no crash, no stream errors', () async {
    await setup();

    final subscriptionId = await client.subscriptionCreate(requestedPublishingInterval: Duration(milliseconds: 20));

    final values = <DynamicValue>[];
    final errors = <Object>[];
    final stream = client.monitor(intNodeId, subscriptionId, samplingInterval: Duration(milliseconds: 20));
    // NOTE: we intentionally KEEP this subscription active — we never cancel it.
    // ignore: cancel_subscriptions
    stream.listen(values.add, onError: errors.add);

    // Wait until data is actively flowing.
    final start = DateTime.now();
    while (values.isEmpty && DateTime.now().difference(start) < Duration(seconds: 5)) {
      await Future.delayed(Duration(milliseconds: 20));
    }
    expect(values, isNotEmpty, reason: 'Data should be flowing before delete()');
    errors.clear(); // Only care about errors caused by the delete().

    // Delete WITHOUT cancelling the stream subscription. On the unpatched client
    // this delivers an in-flight notification / state callback against freed
    // native memory (SEGV); where it survives, it delivers stream errors.
    await client.delete();

    // Give any in-flight notifications a chance to be (wrongly) delivered.
    await Future.delayed(Duration(milliseconds: 300));

    // If the VM is still alive, this runs — proving no SEGV.
    expect(1 + 1, equals(2), reason: 'VM must still be alive after delete()');
    expect(
      errors,
      isEmpty,
      reason: 'delete() must tear the stream down cleanly before freeing the client, so no error should be delivered',
    );

    teardown();
  }, timeout: Timeout(Duration(seconds: 20)));

  test('delete() with MULTIPLE active monitored-item streams: no crash, no stream errors', () async {
    await setup();

    final subscriptionId = await client.subscriptionCreate(requestedPublishingInterval: Duration(milliseconds: 20));

    final received = <int>{};
    final errors = <Object>[];

    // A monitor() stream (single node).
    final streamA = client.monitor(intNodeId, subscriptionId, samplingInterval: Duration(milliseconds: 20));
    // ignore: cancel_subscriptions
    streamA.listen((_) => received.add(1), onError: errors.add);

    // A monitoredItems() stream covering multiple nodes.
    final streamB = client.monitoredItems(
      {
        int2NodeId: [AttributeId.UA_ATTRIBUTEID_VALUE],
        int3NodeId: [AttributeId.UA_ATTRIBUTEID_VALUE],
      },
      subscriptionId,
      samplingInterval: Duration(milliseconds: 20),
    );
    // ignore: cancel_subscriptions
    streamB.listen((_) => received.add(2), onError: errors.add);

    // A second monitor() stream on a separate subscription.
    final subscriptionId2 = await client.subscriptionCreate(requestedPublishingInterval: Duration(milliseconds: 20));
    final streamC = client.monitor(int3NodeId, subscriptionId2, samplingInterval: Duration(milliseconds: 20));
    // ignore: cancel_subscriptions
    streamC.listen((_) => received.add(3), onError: errors.add);

    // Wait until all three streams have delivered data.
    final start = DateTime.now();
    while (received.length < 3 && DateTime.now().difference(start) < Duration(seconds: 8)) {
      await Future.delayed(Duration(milliseconds: 20));
    }
    expect(received, containsAll(<int>[1, 2, 3]), reason: 'All streams should be flowing before delete()');
    errors.clear(); // Only care about errors caused by the delete().

    // Delete with all three streams still active and receiving notifications.
    await client.delete();

    // Give any in-flight notifications a chance to be (wrongly) delivered.
    await Future.delayed(Duration(milliseconds: 300));

    // Liveness proof after delete().
    expect(2 + 2, equals(4), reason: 'VM must still be alive after delete()');
    expect(
      errors,
      isEmpty,
      reason: 'delete() must tear all streams down cleanly before freeing the client, so no error should be delivered',
    );

    teardown();
  }, timeout: Timeout(Duration(seconds: 30)));
}
