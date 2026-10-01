// Regression tests for what a monitored item leaves behind when it ends.
//
// A monitored-item stream owns a NativeCallable (the data callback, whose
// closure captures the item's value map: last value, enum fields, localized
// texts) and, once the server has created it, an item on the server. Both
// have to go whichever way the item ends. The paths pinned here are the ones
// PR #119 fixed, and the ones its review found untested:
//
// - a create the server refuses (BadNodeIdUnknown). A caller that rebuilds a
//   refused item on a backoff ladder walks this path forever, and it never
//   closed the callback: the teardown took its "create still in flight"
//   branch against an already freed request id. Every rebuild leaked one.
// - a partial refusal, where the items the server did create have to be
//   deleted again.
// - a teardown on a dead connection. cancel() used to hang forever, because
//   the DeleteMonitoredItems request is refused before it is sent and never
//   calls back; subscriptionCreate() hung the same way.
//
// A live NativeCallable.isolateLocal keeps its isolate alive, so "the callback
// was released" is observed as "an isolate that did this can exit". The server
// side is observed through Server.statistics.

import 'dart:async';
import 'dart:isolate';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart' show TcpProxy, freeTcpPort, holdPort, waitForChannelDown, waitForStats;

final intNodeId = NodeId.fromString(1, "the.int");
final unknownNodeId = NodeId.fromString(1, "does.not.exist");

/// Runs in its own isolate: rebuild a refused item a few times, tear the
/// client down, return. A live NativeCallable.isolateLocal keeps its isolate
/// alive, so if any rebuild leaks its monitor callback the isolate never
/// exits — the same technique as write_callback_release_test.dart.
Future<void> refusedRebuildsThenReturn((int, SendPort) args) async {
  final (port, report) = args;
  final client = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
  final pump = Timer.periodic(Duration(milliseconds: 5), (_) {
    client.runIterate(Duration(milliseconds: 5));
  });
  await client.connect('opc.tcp://127.0.0.1:$port');
  final subscriptionId = await client.subscriptionCreate(requestedPublishingInterval: Duration(milliseconds: 50));

  var refusals = 0;
  for (var i = 0; i < 3; i++) {
    final done = Completer<void>();
    client
        .monitoredItems({
          unknownNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE],
        }, subscriptionId)
        .listen((_) {}, onError: (_) => refusals++, onDone: done.complete);
    await done.future.timeout(Duration(seconds: 5));
  }

  pump.cancel();
  await client.delete();
  report.send(refusals);
}

/// What [deadConnectionThenReturn] does once its connection is dead.
enum DeadConnectionAction { cancelItem, deleteClientWithItemActive, createSubscription }

/// Runs in its own isolate: connect, wait for the test to take the server
/// away, perform [DeadConnectionAction], delete the client, report, return.
///
/// For the two item actions a live item is monitored first. Its
/// DeleteMonitoredItems request cannot be sent any more, so its native
/// callback has to stay open past the teardown, and the isolate only exits if
/// deleting the client releases it. For createSubscription the request is
/// refused before it is sent, and the isolate only exits if that refusal
/// releases the two native callbacks the request registered.
Future<void> deadConnectionThenReturn((int, SendPort, DeadConnectionAction) args) async {
  final (port, report, action) = args;
  final serverGone = ReceivePort();
  final client = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
  final pump = Timer.periodic(Duration(milliseconds: 5), (_) {
    client.runIterate(Duration(milliseconds: 5));
  });
  await client.connect('opc.tcp://127.0.0.1:$port');

  StreamSubscription<Map<NodeId, DynamicValue>>? subscription;
  if (action != DeadConnectionAction.createSubscription) {
    final subscriptionId = await client.subscriptionCreate(requestedPublishingInterval: Duration(milliseconds: 50));
    final firstValue = Completer<void>();
    subscription = client
        .monitoredItems({
          intNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE],
        }, subscriptionId)
        .listen((_) {
          if (!firstValue.isCompleted) firstValue.complete();
        }, onError: (_) {});
    await firstValue.future;
  }

  report.send(serverGone.sendPort);
  await serverGone.first;
  while (client.state.channelState == SecureChannelState.UA_SECURECHANNELSTATE_OPEN) {
    await Future.delayed(Duration(milliseconds: 20));
  }

  Object? failure;
  try {
    switch (action) {
      case DeadConnectionAction.cancelItem:
        await subscription!.cancel().timeout(Duration(seconds: 3));
      case DeadConnectionAction.deleteClientWithItemActive:
        break;
      case DeadConnectionAction.createSubscription:
        try {
          await client.subscriptionCreate().timeout(Duration(seconds: 3));
          failure = 'subscriptionCreate() completed on a dead connection';
        } on UaStatusException catch (e) {
          if (e.statusCode != UA_STATUSCODE_BADSERVERNOTCONNECTED) failure = e;
        }
    }
    pump.cancel();
    await client.delete();
  } catch (e) {
    failure = e;
  }
  report.send(failure?.toString() ?? 'ok');
}

/// Runs in its own isolate, connected through the test's TCP proxy: monitor a
/// live item, cancel it while the test has the channel cut, and after the
/// reconnect change the value so the item, which the server still has,
/// publishes again. That notification is dispatched into the cancelled
/// stream's native callback, so the callback must still be open; deleting the
/// client then has to release it for the isolate to exit.
Future<void> channelCutCancelThenReturn((int, SendPort) args) async {
  final (proxyPort, report) = args;
  final steps = ReceivePort();
  final nextStep = StreamIterator(steps);
  final client = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
  await client.keepConnected('opc.tcp://127.0.0.1:$proxyPort');
  final subscriptionId = await client.subscriptionCreate(requestedPublishingInterval: Duration(milliseconds: 50));

  Stream<Map<NodeId, DynamicValue>> monitorTheInt() => client.monitoredItems({
    intNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE],
  }, subscriptionId);
  Future<void> waitFor(bool Function() condition) async {
    final deadline = DateTime.now().add(Duration(seconds: 20));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) throw TimeoutException('condition not met');
      await Future.delayed(Duration(milliseconds: 20));
    }
  }

  Object? failure;
  try {
    var seen = false;
    final cancelled = monitorTheInt().listen((_) => seen = true, onError: (_) {});
    await waitFor(() => seen);

    // The test cuts the channel now.
    report.send(steps.sendPort);
    await nextStep.moveNext();
    await waitFor(() => client.state.channelState != SecureChannelState.UA_SECURECHANNELSTATE_OPEN);
    await cancelled.cancel().timeout(Duration(seconds: 3));

    // The test restores the proxy now; the client re-activates its session.
    report.send('cancelled');
    await nextStep.moveNext();
    await waitFor(() => client.state.sessionState == SessionState.UA_SESSIONSTATE_ACTIVATED);

    // A second item on the same node shows when a change has been published:
    // by the time it has seen both writes, the item of the cancelled stream
    // has published the first one into its callback.
    int? latest;
    final witness = monitorTheInt().listen((values) => latest = values[intNodeId]?.value as int?, onError: (_) {});
    for (final value in [43, 44]) {
      await client.write(intNodeId, DynamicValue(value: value, typeId: NodeId.int32));
      await waitFor(() => latest == value);
    }
    report.send('published');
    await nextStep.moveNext();

    await witness.cancel();
    await client.delete();
  } catch (e) {
    failure = e;
  }
  await nextStep.cancel();
  report.send(failure?.toString() ?? 'ok');
}

void main() {
  late int serverPort;
  late Server server;
  late Client client;
  late Timer serverTimer;
  Timer? clientTimer;
  var serverShutdown = false;

  void startClientPump() {
    clientTimer = Timer.periodic(Duration(milliseconds: 10), (_) {
      client.runIterate(Duration(milliseconds: 10));
    });
  }

  void stopClientPump() {
    clientTimer?.cancel();
    clientTimer = null;
  }

  setUp(() async {
    serverPort = await freeTcpPort();
    serverShutdown = false;
    server = Server(port: serverPort, logLevel: LogLevel.UA_LOGLEVEL_ERROR);
    server.start();
    server.addVariableNode(intNodeId, DynamicValue(value: 42, typeId: NodeId.int32, name: "the.int"));
    serverTimer = Timer.periodic(Duration(milliseconds: 10), (_) {
      server.runIterate();
    });

    client = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
    startClientPump();
    await client.connect("opc.tcp://127.0.0.1:$serverPort");
  });

  tearDown(() async {
    stopClientPump();
    serverTimer.cancel();
    if (!serverShutdown) server.shutdown();
    await client.delete();
    if (!serverShutdown) server.delete();
  });

  /// Takes the server away for good, so that every secure channel to it dies.
  Future<void> killServer() async {
    serverTimer.cancel();
    server.shutdown();
    server.delete();
    serverShutdown = true;
    // Keep the port, so a client still reconnecting at this address cannot
    // wander into another suite's server and open a session there.
    await holdPort(serverPort);
  }

  test('a create refused for every node (BadNodeIdUnknown) reports it and closes the stream, '
      'rebuild after rebuild', () async {
    final subscriptionId = await client.subscriptionCreate(requestedPublishingInterval: Duration(milliseconds: 50));

    // The production trigger: the caller rebuilds a refused item forever, on
    // a backoff ladder. Each rebuild must leave nothing behind.
    for (var i = 0; i < 5; i++) {
      final errors = <Object>[];
      final done = Completer<void>();
      client
          .monitoredItems({
            unknownNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE],
          }, subscriptionId)
          .listen((_) {}, onError: errors.add, onDone: done.complete);

      await done.future.timeout(Duration(seconds: 5), onTimeout: () => fail('rebuild $i: the stream never closed'));
      expect(errors, hasLength(1), reason: 'rebuild $i');
      expect(errors.single.toString(), contains('BadNodeIdUnknown'), reason: 'rebuild $i');
    }

    // The client is still healthy after the churn, and the server holds
    // nothing for it but the subscription.
    expect((await client.read(intNodeId)).value, 42);
    expect(server.statistics.currentMonitoredItemCount, 0);
  }, timeout: Timeout(Duration(seconds: 30)));

  test('refused rebuilds release their native monitor callback: the isolate can exit', () async {
    // A refused rebuild used to keep the item's NativeCallable: the old path
    // never closed it (it ran the "create still in flight" branch of the
    // teardown instead).
    final report = ReceivePort();
    final exited = ReceivePort();
    await Isolate.spawn(refusedRebuildsThenReturn, (serverPort, report.sendPort), onExit: exited.sendPort);

    expect(await report.first.timeout(Duration(seconds: 20)), 3, reason: 'every rebuild must be refused');
    await exited.first.timeout(
      Duration(seconds: 10),
      onTimeout: () => fail('the isolate never exited: a NativeCallable is still open after the refused rebuilds'),
    );
  }, timeout: Timeout(Duration(seconds: 45)));

  // Known bug found in the PR #119 review, same on main: the ClientIsolate
  // worker forwards a monitoredItems stream's data and errors but not its done
  // event, so after a refused create the caller gets the error and a stream
  // that never closes.
  test(
    'ClientIsolate: a create refused for every node (BadNodeIdUnknown) reports it and closes the stream',
    () async {
      final isolateClient = await ClientIsolate.create(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
      addTearDown(isolateClient.delete);
      await isolateClient.keepConnected('opc.tcp://127.0.0.1:$serverPort');
      final subscriptionId = await isolateClient.subscriptionCreate(
        requestedPublishingInterval: Duration(milliseconds: 50),
      );

      final errors = <Object>[];
      final done = Completer<void>();
      isolateClient
          .monitoredItems({
            unknownNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE],
          }, subscriptionId)
          .listen((_) {}, onError: errors.add, onDone: done.complete);

      await done.future.timeout(
        Duration(seconds: 5),
        onTimeout: () => fail('the stream never closed after the refused create (errors so far: $errors)'),
      );
      expect(errors.single.toString(), contains('BadNodeIdUnknown'));
    },
    timeout: Timeout(Duration(seconds: 30)),
    skip:
        'BUG: the ClientIsolate worker does not forward the done event of a monitoredItems stream, '
        'so the stream never closes after a refused create',
  );

  test('a partial refusal (one node unknown, one fine) closes the stream and deletes the created item', () async {
    final subscriptionId = await client.subscriptionCreate(requestedPublishingInterval: Duration(milliseconds: 50));

    final errors = <Object>[];
    final done = Completer<void>();
    client
        .monitoredItems({
          intNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE],
          unknownNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE],
        }, subscriptionId)
        .listen((_) {}, onError: errors.add, onDone: done.complete);

    await done.future.timeout(Duration(seconds: 5), onTimeout: () => fail('the stream never closed'));
    expect(errors.single.toString(), contains('BadNodeIdUnknown'));

    // Guards PR #119 review finding 5: the item the server DID create has to
    // be deleted again, and nothing checked that it is.
    await waitForStats(
      server,
      (s) => s.currentMonitoredItemCount == 0,
      reason: 'the item created by the partly refused request to be deleted on the server',
    );
    expect((await client.read(intNodeId)).value, 42);
  }, timeout: Timeout(Duration(seconds: 30)));

  test('cancelling a live item deletes it on the server', () async {
    final subscriptionId = await client.subscriptionCreate(requestedPublishingInterval: Duration(milliseconds: 50));

    final firstValue = Completer<void>();
    final sub = client.monitor(intNodeId, subscriptionId, samplingInterval: Duration(milliseconds: 50)).listen((_) {
      if (!firstValue.isCompleted) firstValue.complete();
    });
    await firstValue.future.timeout(Duration(seconds: 5), onTimeout: () => fail('no initial value'));
    expect(server.statistics.currentMonitoredItemCount, greaterThan(0), reason: 'a live item exists on the server');

    await sub.cancel();
    await waitForStats(
      server,
      (s) => s.currentMonitoredItemCount == 0,
      reason: 'the cancelled items to be deleted on the server',
    );
  }, timeout: Timeout(Duration(seconds: 15)));

  test('cancelling while the create is still in flight leaves no item on the server', () async {
    final subscriptionId = await client.subscriptionCreate(requestedPublishingInterval: Duration(milliseconds: 50));

    // Pause the pump so the create request cannot be answered before the
    // cancel is issued.
    stopClientPump();
    final sub = client
        .monitoredItems({
          intNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE],
        }, subscriptionId)
        .listen((_) {}, onError: (_) {});
    unawaited(sub.cancel());
    startClientPump();

    // Requests are answered in order. The first read is answered after the
    // create, whose response makes the client send the deferred delete; the
    // second read is sent after that delete, so it is answered after it.
    expect((await client.read(intNodeId)).value, 42);
    expect((await client.read(intNodeId)).value, 42);
    expect(server.statistics.currentMonitoredItemCount, 0);
  }, timeout: Timeout(Duration(seconds: 15)));

  test('cancelling on a dead connection completes', () async {
    final subscriptionId = await client.subscriptionCreate(requestedPublishingInterval: Duration(milliseconds: 50));

    final firstValue = Completer<void>();
    final sub = client
        .monitoredItems({
          intNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE],
        }, subscriptionId)
        .listen((_) {
          if (!firstValue.isCompleted) firstValue.complete();
        }, onError: (_) {});
    await firstValue.future.timeout(Duration(seconds: 5), onTimeout: () => fail('no initial value'));

    // Kill the server so the secure channel is gone by the time we cancel:
    // the DeleteMonitoredItems request then cannot even be sent.
    await killServer();
    await waitForChannelDown(client);

    // A cancel that cannot reach the server must still finish: the caller
    // awaits it.
    await sub.cancel().timeout(
      Duration(seconds: 3),
      onTimeout: () => fail('cancel() never completed on a dead connection'),
    );
  }, timeout: Timeout(Duration(seconds: 15)));

  /// Spawns [deadConnectionThenReturn], takes the server away once the
  /// isolate is ready, and fails with [stillOpen] if the isolate cannot exit.
  Future<void> expectIsolateExitsAfter(DeadConnectionAction action, {required String stillOpen}) async {
    final report = ReceivePort();
    final exited = ReceivePort();
    final events = StreamIterator(report);
    await Isolate.spawn(deadConnectionThenReturn, (serverPort, report.sendPort, action), onExit: exited.sendPort);

    expect(await events.moveNext().timeout(Duration(seconds: 20)), isTrue);
    final serverGone = events.current as SendPort;
    await killServer();
    serverGone.send(null);

    expect(await events.moveNext().timeout(Duration(seconds: 20)), isTrue);
    expect(events.current, 'ok', reason: 'the isolate must get through its teardown on a dead connection');
    await events.cancel();
    await exited.first.timeout(Duration(seconds: 10), onTimeout: () => fail('the isolate never exited: $stillOpen'));
  }

  // Guards PR #119 review finding 4: a teardown that cannot reach the server
  // has to leave the item's native callback open, and nothing closed it
  // afterwards, so the isolate could never exit.
  test('an item cancelled on a dead connection releases its native callback with the client: '
      'the isolate can exit', () async {
    await expectIsolateExitsAfter(
      DeadConnectionAction.cancelItem,
      stillOpen:
          'the native callback of an item that could not be deleted on the server '
          'is still open after Client.delete()',
    );
  }, timeout: Timeout(Duration(seconds: 60)));

  test('an item still active when the client is deleted on a dead connection releases its native callback: '
      'the isolate can exit', () async {
    await expectIsolateExitsAfter(
      DeadConnectionAction.deleteClientWithItemActive,
      stillOpen:
          'the native callback of an item that could not be deleted on the server '
          'is still open after Client.delete()',
    );
  }, timeout: Timeout(Duration(seconds: 60)));

  // Guards PR #119 review finding 5: no test failed when the check of
  // UA_Client_Subscriptions_create_async's return code was reverted.
  test('subscriptionCreate() on a dead connection fails with BadServerNotConnected instead of hanging', () async {
    await killServer();
    await waitForChannelDown(client);

    await expectLater(
      client.subscriptionCreate().timeout(
        Duration(seconds: 3),
        onTimeout: () => fail('subscriptionCreate() never completed on a dead connection'),
      ),
      throwsA(isA<UaStatusException>().having((e) => e.statusCode, 'statusCode', UA_STATUSCODE_BADSERVERNOTCONNECTED)),
    );
  }, timeout: Timeout(Duration(seconds: 30)));

  test('subscriptionCreate() refused on a dead connection releases its native callbacks: '
      'the isolate can exit', () async {
    await expectIsolateExitsAfter(
      DeadConnectionAction.createSubscription,
      stillOpen: 'a native callback of the refused subscriptionCreate() is still open after Client.delete()',
    );
  }, timeout: Timeout(Duration(seconds: 60)));

  // Guards the use-after-free rule at the same spot (PR #119 review finding
  // 3): the item survives on the server when only the channel drops, so its
  // callback must stay open until the client is deleted. Closing it earlier
  // aborts the VM with "Callback invoked after it has been deleted".
  test('an item cancelled while only the channel is down still takes its notifications after the reconnect, '
      'and is released with the client', () async {
    final proxy = await TcpProxy.start(serverPort);
    final report = ReceivePort();
    final exited = ReceivePort();
    final events = StreamIterator(report);
    await Isolate.spawn(channelCutCancelThenReturn, (proxy.port, report.sendPort), onExit: exited.sendPort);
    Future<Object?> nextEvent() async {
      expect(await events.moveNext().timeout(Duration(seconds: 30)), isTrue);
      return events.current;
    }

    final nextStep = await nextEvent() as SendPort;
    await proxy.cut();
    nextStep.send(null);

    expect(await nextEvent(), 'cancelled', reason: 'cancel() must complete while the channel is down');
    await proxy.resume();
    nextStep.send(null);

    expect(await nextEvent(), 'published');
    final stats = server.statistics;
    expect(stats.cumulatedSessionCount, 2, reason: 'precondition: the isolate client kept its session over the cut');
    // One item of the cancelled stream, one of the witness stream. If the
    // delete is ever retried after a reconnect this becomes 1, and this test
    // no longer exercises the callback of the cancelled stream.
    expect(
      stats.currentMonitoredItemCount,
      2,
      reason: 'precondition: the cancelled item is still on the server and publishes into its callback',
    );
    nextStep.send(null);

    expect(await nextEvent(), 'ok');
    await events.cancel();
    await exited.first.timeout(
      Duration(seconds: 10),
      onTimeout: () => fail('the isolate never exited: the native callback of the cancelled item is still open'),
    );
  }, timeout: Timeout(Duration(seconds: 90)));
}
