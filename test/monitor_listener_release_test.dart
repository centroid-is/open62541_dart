// Regression tests for the monitored-item listener leak.
//
// Every monitored-item stream attaches three listeners to the client config's
// broadcast streams (subscription inactivity, subscription deleted, client
// state) so it can forward those conditions as errors. Each listener closure
// captures the item's own value map, so a listener that outlives its item pins
// the key's last value — enum fields, localized texts, node ids and all.
//
// Those listeners used to be released lazily: each began with
// `if (controller.isClosed) { sub?.cancel(); return; }`, which only runs on
// the NEXT event on that stream — and on a quiet client that is never. On a
// production HMI the caller tears down and rebuilds a monitored item whenever
// the server gives a hard answer (BadNodeIdUnknown, ...), forever, so the
// leaked listeners (and everything they capture) grew without bound: RSS
// climbed 72–122 MiB/h until the panel was OOM-killed.
//
// The property pinned here: after ANY path that ends a monitored item, the
// config streams have no listener left from it — immediately, without waiting
// for an unrelated event to arrive.

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
    // Nothing else in these tests subscribes to the config streams, so the
    // gauge starts clean and reads false exactly when no monitored item holds
    // a listener.
    expect(client.config.hasStreamListeners, isFalse);
  });

  tearDown(() async {
    stopClientPump();
    serverTimer.cancel();
    if (!serverShutdown) server.shutdown();
    await client.delete();
    if (!serverShutdown) server.delete();
  });

  test('a create refused for every node (BadNodeIdUnknown) releases the listeners, rebuild after rebuild', () async {
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
      // Released by the time the stream is done — not on the next state
      // change, which on a quiet client never comes.
      expect(client.config.hasStreamListeners, isFalse, reason: 'rebuild $i left a listener behind');
    }

    // The client is still healthy after the churn.
    expect((await client.read(intNodeId)).value, 42);
  }, timeout: Timeout(Duration(seconds: 30)));

  test('refused rebuilds release their native monitor callback: the isolate can exit', () async {
    // The listeners are one half of what a refused rebuild used to keep; the
    // other is the item's NativeCallable, which the old path never closed
    // (it ran the "create still in flight" branch of the teardown instead).
    final report = ReceivePort();
    final exited = ReceivePort();
    await Isolate.spawn(refusedRebuildsThenReturn, (serverPort, report.sendPort), onExit: exited.sendPort);

    expect(await report.first.timeout(Duration(seconds: 20)), 3, reason: 'every rebuild must be refused');
    await exited.first.timeout(
      Duration(seconds: 10),
      onTimeout: () => fail('the isolate never exited: a NativeCallable is still open after the refused rebuilds'),
    );
  }, timeout: Timeout(Duration(seconds: 45)));

  test('a partial refusal (one node unknown, one fine) releases the listeners and deletes the created item', () async {
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
    expect(client.config.hasStreamListeners, isFalse);

    // Guards PR #119 review finding 5: the item the server DID create has to
    // be deleted again, and nothing checked that it is.
    await waitForStats(
      server,
      (s) => s.currentMonitoredItemCount == 0,
      reason: 'the item created by the partly refused request to be deleted on the server',
    );
    expect((await client.read(intNodeId)).value, 42);
  }, timeout: Timeout(Duration(seconds: 30)));

  test('cancelling a live item releases the listeners as part of the cancel', () async {
    final subscriptionId = await client.subscriptionCreate(requestedPublishingInterval: Duration(milliseconds: 50));

    final values = <DynamicValue>[];
    final sub = client
        .monitor(intNodeId, subscriptionId, samplingInterval: Duration(milliseconds: 50))
        .listen(values.add);
    await Future.delayed(Duration(milliseconds: 500));
    expect(values, isNotEmpty, reason: 'should have received the initial value');
    expect(client.config.hasStreamListeners, isTrue, reason: 'a live item holds its listeners');

    await sub.cancel();
    expect(client.config.hasStreamListeners, isFalse);
  }, timeout: Timeout(Duration(seconds: 15)));

  test('cancelling while the create is still in flight leaves no listener', () async {
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

    // Let the create response (and the deferred delete it triggers) go by.
    await Future.delayed(Duration(milliseconds: 500));
    expect(client.config.hasStreamListeners, isFalse);
    expect((await client.read(intNodeId)).value, 42);
  }, timeout: Timeout(Duration(seconds: 15)));

  test('cancelling on a dead connection completes and releases the listeners', () async {
    final subscriptionId = await client.subscriptionCreate(requestedPublishingInterval: Duration(milliseconds: 50));

    final values = <Map<NodeId, DynamicValue>>[];
    final sub = client
        .monitoredItems({
          intNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE],
        }, subscriptionId)
        .listen(values.add, onError: (_) {});
    await Future.delayed(Duration(milliseconds: 500));
    expect(values, isNotEmpty);

    // Kill the server so the secure channel is gone by the time we cancel:
    // the DeleteMonitoredItems request then cannot even be sent.
    serverTimer.cancel();
    server.shutdown();
    server.delete();
    serverShutdown = true;
    // Keep the port, so the client still reconnecting at this address
    // cannot wander into another suite's server and open a session there.
    await holdPort(serverPort);
    await Future.delayed(Duration(milliseconds: 500));

    // A cancel that cannot reach the server must still finish (the caller
    // awaits it) and must still let go of the listeners.
    await sub.cancel().timeout(Duration(seconds: 3), onTimeout: () => fail('cancel() never completed'));
    expect(client.config.hasStreamListeners, isFalse);
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
    serverTimer.cancel();
    server.shutdown();
    server.delete();
    serverShutdown = true;
    await holdPort(serverPort);
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
    serverTimer.cancel();
    server.shutdown();
    server.delete();
    serverShutdown = true;
    await holdPort(serverPort);
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
