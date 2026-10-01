// Scenario for monitor_delete_response_lost_test.dart. It runs as a process of
// its own because the bug it reproduces aborts the VM ("Callback invoked
// after it has been deleted"), which would take the test runner down with it.
//
//   1. monitor a live item through a TCP proxy;
//   2. black-hole the link and cancel the stream: DeleteMonitoredItems is
//      sent, the server never sees it;
//   3. cut the link: the pending delete is answered locally with
//      BadSecureChannelClosed, and cancel() completes;
//   4. restore the link: the client re-activates its session, where the item
//      still exists, and the next data change is dispatched into the
//      cancelled stream's native callback.
//
// The process exits with 0 when it gets through that and can then delete the
// client and run out of work, which it only does if every native callback has
// been released. It prints "FAILED: ..." and exits with 1 when a step does not
// happen.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:open62541/open62541.dart';
import '../common.dart';

/// Hosts the server in an isolate of its own, so it keeps answering whatever
/// the client is doing. Sends the port it takes requests on; any message to
/// that port is answered with the current monitored item count.
void serverMain((SendPort, int) args) {
  final (toScenario, port) = args;
  final server = Server(port: port, logLevel: LogLevel.UA_LOGLEVEL_ERROR);
  server.start();
  addBasicVariables(server);
  Timer.periodic(const Duration(milliseconds: 10), (_) => server.runIterate());
  final requests = ReceivePort();
  requests.listen((_) => toScenario.send(server.statistics.currentMonitoredItemCount));
  toScenario.send(requests.sendPort);
}

Future<void> waitFor(String what, bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('timed out waiting for $what');
    await Future.delayed(const Duration(milliseconds: 20));
  }
}

Future<void> main() async {
  final serverPort = await freeTcpPort();
  final fromServer = ReceivePort();
  final serverReplies = StreamIterator(fromServer);
  final serverIsolate = await Isolate.spawn(serverMain, (fromServer.sendPort, serverPort));
  await serverReplies.moveNext();
  final toServer = serverReplies.current as SendPort;
  Future<int> itemsOnServer() async {
    toServer.send(null);
    await serverReplies.moveNext();
    return serverReplies.current as int;
  }

  final proxy = await TcpProxy.start(serverPort, cutOnTearDown: false);
  final client = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
  try {
    await client.keepConnected('opc.tcp://127.0.0.1:${proxy.port}').timeout(const Duration(seconds: 20));
    final subscriptionId = await client.subscriptionCreate(
      requestedPublishingInterval: const Duration(milliseconds: 50),
    );
    Stream<Map<NodeId, DynamicValue>> monitorTheInt() => client.monitoredItems({
      intNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE],
    }, subscriptionId);

    var seen = false;
    final cancelled = monitorTheInt().listen((_) => seen = true, onError: (_) {});
    await waitFor('the first value', () => seen);

    proxy.stall();
    final cancel = cancelled.cancel();
    print('delete sent into the stalled link');
    await proxy.cut();
    await cancel.timeout(const Duration(seconds: 20));
    print('cancel() completed without a delete response');

    await proxy.resume();
    await waitFor(
      'the session to be re-activated',
      () => client.state.sessionState == SessionState.UA_SESSIONSTATE_ACTIVATED,
    );

    // A second item on the same node shows when a change has been published:
    // by the time it has seen both writes, the item of the cancelled stream
    // has published the first one into its callback.
    int? latest;
    final witness = monitorTheInt().listen((values) => latest = values[intNodeId]?.value as int?, onError: (_) {});
    for (final value in [43, 44]) {
      await client.write(intNodeId, DynamicValue(value: value, typeId: NodeId.int32));
      await waitFor('value $value on the witness stream', () => latest == value);
    }
    final items = await itemsOnServer();
    if (items != 2) {
      throw StateError(
        'precondition: expected the cancelled item and the witness item on the server, found $items items',
      );
    }
    print('the cancelled item published after the reconnect');

    await witness.cancel();
    await client.delete();
    print('survived');
  } catch (e) {
    print('FAILED: $e');
    exit(1);
  }
  await serverReplies.cancel();
  await proxy.cut();
  serverIsolate.kill();
}
