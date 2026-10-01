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
// - a teardown whose delete never took effect, because it could not be sent
//   or its response was lost with the channel. The item survives on the
//   server with its session and publishes again after the reconnect, so its
//   callback must stay open until the client is deleted. Closing it earlier
//   aborts the VM ("Callback invoked after it has been deleted").
//
// A live NativeCallable.isolateLocal keeps its isolate alive, so "the callback
// was released" is observed as "an isolate that did this can exit". The server
// side is observed through Server.statistics.
//
// Every client here connects through a TcpProxy. A dead connection is the
// proxy cut: the server stays up and its port is never handed back while a
// client is still trying to reconnect to it.

import 'dart:async';
import 'dart:isolate';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart' show TcpProxy, freeTcpPort, waitForChannelDown, waitForStats;

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

/// Runs in its own isolate: connect through the test's proxy, wait for the
/// test to cut it for good, perform [DeadConnectionAction], delete the client,
/// report, return.
///
/// For the two item actions a live item is monitored first. Its
/// DeleteMonitoredItems request cannot be sent any more, so its native
/// callback has to stay open past the teardown, and the isolate only exits if
/// deleting the client releases it. For createSubscription the request is
/// refused before it is sent, and the isolate only exits if that refusal
/// releases the two native callbacks the request registered.
Future<void> deadConnectionThenReturn((int, SendPort, DeadConnectionAction) args) async {
  final (port, report, action) = args;
  final connectionCut = ReceivePort();
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

  report.send(connectionCut.sendPort);
  await connectionCut.first;
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

/// How the DeleteMonitoredItems of [channelCutCancelThenReturn] fails.
enum LostDelete {
  /// The channel is already down when the stream is cancelled: the request is
  /// refused before it is sent.
  notSent,

  /// The link is black-holed when the stream is cancelled and cut afterwards:
  /// the request is sent, the server never sees it, and it is answered
  /// locally with BadSecureChannelClosed when the channel closes.
  responseLost,
}

/// Runs in its own isolate, connected through the test's TCP proxy: monitor a
/// live item, cancel it so that its delete fails as [LostDelete] says, and
/// after the reconnect change the value so the item, which the server still
/// has, publishes again. That notification is dispatched into the cancelled
/// stream's native callback, so the callback must still be open; deleting the
/// client then has to release it for the isolate to exit.
///
/// Reports 'session lost' if the client came back with a new session: the
/// item is gone with the old one, and the run shows nothing.
Future<void> channelCutCancelThenReturn((int, SendPort, LostDelete) args) async {
  final (proxyPort, report, lostDelete) = args;
  final steps = ReceivePort();
  final nextStep = StreamIterator(steps);
  final client = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
  await client.keepConnected('opc.tcp://127.0.0.1:$proxyPort');
  final subscriptionId = await client.subscriptionCreate(requestedPublishingInterval: Duration(milliseconds: 50));
  // open62541 drops its subscriptions when it has to create a new session.
  var sessionLost = false;
  final deletions = client.config.subscriptionDeletedStream.listen((id) {
    if (id == subscriptionId) sessionLost = true;
  });

  Stream<Map<NodeId, DynamicValue>> monitorTheInt() => client.monitoredItems({
    intNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE],
  }, subscriptionId);
  Future<void> waitFor(String what, bool Function() condition) async {
    final deadline = DateTime.now().add(Duration(seconds: 20));
    while (!condition()) {
      if (sessionLost) throw StateError('session lost');
      if (DateTime.now().isAfter(deadline)) throw TimeoutException('timed out waiting for $what');
      await Future.delayed(Duration(milliseconds: 20));
    }
  }

  // The first requests after a reconnect can still fail, with the session
  // not quite back; what matters is that the write gets through in the end.
  Future<void> writeOnceUsable(int value) async {
    final deadline = DateTime.now().add(Duration(seconds: 20));
    while (true) {
      await waitFor('an activated session', () => client.state.sessionState == SessionState.UA_SESSIONSTATE_ACTIVATED);
      try {
        await client.write(intNodeId, DynamicValue(value: value, typeId: NodeId.int32));
        return;
      } on UaStatusException {
        if (sessionLost) throw StateError('session lost');
        if (DateTime.now().isAfter(deadline)) rethrow;
        await Future.delayed(Duration(milliseconds: 50));
      }
    }
  }

  Object? failure;
  try {
    var seen = false;
    final cancelled = monitorTheInt().listen((_) => seen = true, onError: (_) {});
    await waitFor('the first value', () => seen);

    final Future<void> cancel;
    switch (lostDelete) {
      case LostDelete.notSent:
        // The test cuts the channel now.
        report.send(steps.sendPort);
        await nextStep.moveNext();
        await waitFor(
          'the channel to go down',
          () => client.state.channelState != SecureChannelState.UA_SECURECHANNELSTATE_OPEN,
        );
        cancel = cancelled.cancel();
      case LostDelete.responseLost:
        // The test black-holes the link now, and cuts it once the delete is
        // on its way.
        report.send(steps.sendPort);
        await nextStep.moveNext();
        cancel = cancelled.cancel();
        report.send('delete sent');
        await nextStep.moveNext();
    }
    await cancel.timeout(Duration(seconds: 20));

    // The test restores the proxy now; the client re-activates its session.
    report.send('cancelled');
    await nextStep.moveNext();

    // The item of the cancelled stream publishes this change into its
    // callback. A second item on the same node shows when: once it has seen
    // the next change, the first one has been published to both.
    await writeOnceUsable(43);
    int? latest;
    final witness = monitorTheInt().listen((values) => latest = values[intNodeId]?.value as int?, onError: (_) {});
    await waitFor('the witness stream', () => latest != null);
    await writeOnceUsable(44);
    await waitFor('value 44 on the witness stream', () => latest == 44);
    report.send('published');
    await nextStep.moveNext();

    await witness.cancel();
    await deletions.cancel();
    await client.delete();
  } catch (e) {
    failure = sessionLost ? 'session lost' : e;
  }
  await nextStep.cancel();
  report.send(failure?.toString() ?? 'ok');
}

void main() {
  late int serverPort;
  late Server server;
  late TcpProxy proxy;
  late Client client;
  late Timer serverTimer;
  Timer? clientTimer;

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
    server = Server(port: serverPort, logLevel: LogLevel.UA_LOGLEVEL_ERROR);
    server.start();
    server.addVariableNode(intNodeId, DynamicValue(value: 42, typeId: NodeId.int32, name: "the.int"));
    serverTimer = Timer.periodic(Duration(milliseconds: 10), (_) {
      server.runIterate();
    });

    proxy = await TcpProxy.start(serverPort);
    client = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
    startClientPump();
    await client.connect("opc.tcp://127.0.0.1:${proxy.port}");
  });

  tearDown(() async {
    stopClientPump();
    serverTimer.cancel();
    server.shutdown();
    await client.delete();
    server.delete();
  });

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
    await Isolate.spawn(refusedRebuildsThenReturn, (proxy.port, report.sendPort), onExit: exited.sendPort);

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

  test('cancelling while the create is still in flight leaves the client usable', () async {
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

    expect((await client.read(intNodeId)).value, 42);
    // What is left on the server is not asserted here. The cancel is a
    // blocking call, and this server is pumped on the client's isolate, so
    // it cannot answer for the whole request timeout. The create is then as
    // old as its own timeout, and whether its response or that timeout wins
    // afterwards is a race; when the timeout wins, the client never learns
    // the item's id. cancel_inflight_orphan_test.dart asserts the server
    // side, with the server on an isolate of its own.
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

    // Cut the connection so the secure channel is gone by the time we
    // cancel: the DeleteMonitoredItems request then cannot even be sent.
    proxy.cut();
    await waitForChannelDown(client);

    // A cancel that cannot reach the server must still finish: the caller
    // awaits it.
    await sub.cancel().timeout(
      Duration(seconds: 3),
      onTimeout: () => fail('cancel() never completed on a dead connection'),
    );
  }, timeout: Timeout(Duration(seconds: 15)));

  /// Spawns [deadConnectionThenReturn], cuts its connection once the isolate
  /// is ready, and fails with [stillOpen] if the isolate cannot exit.
  Future<void> expectIsolateExitsAfter(DeadConnectionAction action, {required String stillOpen}) async {
    final report = ReceivePort();
    final exited = ReceivePort();
    final events = StreamIterator(report);
    await Isolate.spawn(deadConnectionThenReturn, (proxy.port, report.sendPort, action), onExit: exited.sendPort);

    expect(await events.moveNext().timeout(Duration(seconds: 20)), isTrue);
    final connectionCut = events.current as SendPort;
    proxy.cut();
    connectionCut.send(null);

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
    proxy.cut();
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

  // Guards the use-after-free rule on the two paths where a delete does not
  // take effect (PR #119 review finding 3, and the abort found in that
  // review): the item survives on the server while the session lives, so its
  // callback must stay open until the client is deleted. If it is closed
  // earlier, these tests abort the VM with "Callback invoked after it has
  // been deleted".
  for (final lostDelete in LostDelete.values) {
    final how = switch (lostDelete) {
      LostDelete.notSent => 'while only the channel is down',
      LostDelete.responseLost => 'whose delete response is lost with the channel',
    };
    test('an item cancelled $how still takes its notifications after the reconnect, '
        'and is released with the client', () async {
      final sessionsBefore = server.statistics.cumulatedSessionCount;
      final report = ReceivePort();
      final exited = ReceivePort();
      final events = StreamIterator(report);
      await Isolate.spawn(channelCutCancelThenReturn, (
        proxy.port,
        report.sendPort,
        lostDelete,
      ), onExit: exited.sendPort);
      Future<Object?> nextEvent() async {
        expect(await events.moveNext().timeout(Duration(seconds: 60)), isTrue);
        return events.current;
      }

      final nextStep = await nextEvent() as SendPort;
      switch (lostDelete) {
        case LostDelete.notSent:
          proxy.cut();
        case LostDelete.responseLost:
          proxy.stall();
          nextStep.send(null);
          expect(await nextEvent(), 'delete sent');
          proxy.cut();
      }
      nextStep.send(null);

      expect(await nextEvent(), 'cancelled', reason: 'cancel() must complete although the delete went nowhere');
      proxy.resume();
      nextStep.send(null);

      // If the client had to create a new session, the cancelled item is gone
      // with the old one and nothing was published into its callback: the
      // run would show nothing, so it must not pass.
      expect(
        await nextEvent(),
        'published',
        reason: 'the client must come back from the cut on the session it had, and publish',
      );
      final stats = server.statistics;
      expect(
        stats.cumulatedSessionCount,
        sessionsBefore + 1,
        reason: 'precondition: the isolate client re-activated its session, it did not create a new one',
      );
      // One item of the cancelled stream, one of the witness stream. If the
      // delete is ever retried after a reconnect this becomes 1, and this
      // test no longer exercises the callback of the cancelled stream.
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
    }, timeout: Timeout(Duration(seconds: 120)));
  }
}
