// Regression tests for the PR #119 review: tearing down a monitoredItems
// stream that has no monitored item behind it.
//
// When the server refuses every item of a create with a *tolerated* status
// (BadAttributeIdInvalid, e.g. the Value attribute of an Object node), the
// stream neither fails nor closes: it stays open with nothing created on the
// server. PR #119 made the teardown of a stream in that state reach a
// `throw 'This should not happen'`, so cancel() threw, Client.delete() threw
// before the native client was freed, and ClientIsolate.delete() failed and
// left the worker isolate, the session and the subscription behind. Every
// existing test passed, in all nine CI jobs: nothing cancelled or deleted a
// stream in that state.

import 'dart:async';
import 'dart:isolate';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart';

/// The Objects folder. An Object node has no Value attribute, so monitoring it
/// is answered with BadAttributeIdInvalid, which monitoredItems tolerates.
final objectsFolderId = NodeId.fromNumeric(0, 85);

/// Listens to a stream whose only item the server refuses with a tolerated
/// status, and returns once the create has been answered.
Future<StreamSubscription<Map<NodeId, DynamicValue>>> listenToNoItemStream(
  ClientApi client,
  int subscriptionId, {
  void Function(Object error)? onError,
  void Function()? onDone,
}) async {
  final subscription = client
      .monitoredItems({
        objectsFolderId: [AttributeId.UA_ATTRIBUTEID_VALUE],
      }, subscriptionId)
      .listen((_) {}, onError: onError ?? (_) {}, onDone: onDone);
  // Requests are answered in order, so once this read is back the create has
  // been answered as well.
  await client.read(intNodeId);
  return subscription;
}

/// Runs in its own isolate: open a stream that ends up with no item, cancel
/// it ([cancelFirst]) or leave it active, delete the client, report, return.
/// A live NativeCallable.isolateLocal keeps its isolate alive, so the isolate
/// only exits if the stream's native callback was released on the way.
Future<void> noItemStreamThenReturn((int, SendPort, bool) args) async {
  final (port, report, cancelFirst) = args;
  final client = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
  final pump = Timer.periodic(Duration(milliseconds: 5), (_) {
    client.runIterate(Duration(milliseconds: 5));
  });
  await client.connect('opc.tcp://127.0.0.1:$port');
  final subscriptionId = await client.subscriptionCreate(requestedPublishingInterval: Duration(milliseconds: 50));
  final subscription = await listenToNoItemStream(client, subscriptionId);

  Object? failure;
  try {
    if (cancelFirst) await subscription.cancel();
    pump.cancel();
    await client.delete();
  } catch (e) {
    failure = e;
  }
  report.send(failure?.toString() ?? 'ok');
}

void main() {
  late int serverPort;
  late Server server;
  late Timer serverTimer;

  setUp(() async {
    serverPort = await freeTcpPort();
    server = Server(port: serverPort, logLevel: LogLevel.UA_LOGLEVEL_ERROR);
    server.start();
    addBasicVariables(server);
    serverTimer = Timer.periodic(Duration(milliseconds: 10), (_) {
      server.runIterate();
    });
  });

  tearDown(() {
    serverTimer.cancel();
    server.shutdown();
    server.delete();
  });

  // Guards the PR #119 review regression: cancel() and Client.delete() threw
  // 'This should not happen' for a stream whose every item was refused with a
  // tolerated status.
  group('Client, stream with every item refused with a tolerated status', () {
    late Client client;
    late Timer clientTimer;
    late int subscriptionId;

    setUp(() async {
      client = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
      clientTimer = Timer.periodic(Duration(milliseconds: 10), (_) {
        client.runIterate(Duration(milliseconds: 10));
      });
      await client.connect('opc.tcp://127.0.0.1:$serverPort');
      subscriptionId = await client.subscriptionCreate(requestedPublishingInterval: Duration(milliseconds: 50));
    });

    tearDown(() => clientTimer.cancel());

    test('cancel() completes without throwing and leaves the client usable', () async {
      final errors = <Object>[];
      var done = false;
      final subscription = await listenToNoItemStream(
        client,
        subscriptionId,
        onError: errors.add,
        onDone: () => done = true,
      );
      expect(errors, isEmpty, reason: 'precondition: the refusal is tolerated, so the stream reports no error');
      expect(done, isFalse, reason: 'precondition: the stream stays open');
      expect(server.statistics.currentMonitoredItemCount, 0, reason: 'precondition: the server created no item');

      try {
        await subscription.cancel();
      } catch (e) {
        fail('cancel() of a stream with no monitored item threw: $e');
      }

      expect((await client.read(intNodeId)).value, 1);
      expect(server.statistics.currentSubscriptionCount, 1, reason: 'the subscription is not touched by the cancel');
      await client.delete();
    }, timeout: Timeout(Duration(seconds: 30)));

    test('Client.delete() with the stream still active completes and closes the session', () async {
      final streamDone = Completer<void>();
      await listenToNoItemStream(client, subscriptionId, onDone: streamDone.complete);
      expect(server.statistics.currentSessionCount, 1);

      try {
        await client.delete();
      } catch (e) {
        fail('Client.delete() with a stream with no monitored item active threw: $e');
      }

      await streamDone.future.timeout(
        Duration(seconds: 5),
        onTimeout: () => fail('Client.delete() did not close the active stream'),
      );
      final stats = await waitForStats(
        server,
        (s) => s.currentSessionCount == 0,
        reason: 'the session to be closed on the server after Client.delete()',
      );
      expect(stats.currentSubscriptionCount, 0);
    }, timeout: Timeout(Duration(seconds: 30)));

    for (final cancelFirst in [true, false]) {
      final how = cancelFirst ? 'cancelled' : 'still active when the client is deleted';
      test('a stream with no monitored item that is $how releases its native callback: the isolate can exit', () async {
        final report = ReceivePort();
        final exited = ReceivePort();
        await Isolate.spawn(noItemStreamThenReturn, (
          serverPort,
          report.sendPort,
          cancelFirst,
        ), onExit: exited.sendPort);

        expect(
          await report.first.timeout(Duration(seconds: 20)),
          'ok',
          reason: 'cancel() / Client.delete() must not throw for a stream with no monitored item',
        );
        await exited.first.timeout(
          Duration(seconds: 10),
          onTimeout: () =>
              fail('the isolate never exited: the native callback of a stream with no monitored item is still open'),
        );
      }, timeout: Timeout(Duration(seconds: 45)));
    }
  });

  // Guards the same PR #119 review regression through ClientIsolate, where it
  // cost more: delete() failed with 'This should not happen', the worker
  // isolate was never killed and the server kept the session and subscription.
  group('ClientIsolate', () {
    late IsolateWatch watch;
    late ClientIsolate client;
    late String worker;
    late int subscriptionId;

    setUpAll(() async => watch = await IsolateWatch.start());
    tearDownAll(() => watch.stop());

    setUp(() async {
      final before = await watch.isolates();
      client = await ClientIsolate.create(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
      worker = (await watch.isolates()).difference(before).single;
      await client.keepConnected('opc.tcp://127.0.0.1:$serverPort');
      subscriptionId = await client.subscriptionCreate(requestedPublishingInterval: Duration(milliseconds: 50));
    });

    /// Deletes [client] and checks everything it owned is gone: the worker
    /// isolate, and the session and subscription on the server.
    Future<void> expectDeleteLeavesNothingBehind() async {
      Object? deleteError;
      try {
        await client.delete();
      } catch (e) {
        deleteError = e;
      }
      await watch.expectGone(
        worker,
        reason:
            'the ClientIsolate worker isolate is still alive after delete() '
            '(delete() answered: ${deleteError ?? 'ok'})',
      );
      expect(deleteError, isNull, reason: 'ClientIsolate.delete() must complete without an error');
      await waitForStats(
        server,
        (s) => s.currentSessionCount == 0 && s.currentSubscriptionCount == 0,
        reason: 'no session and no subscription left on the server after ClientIsolate.delete()',
      );
    }

    test('cancelling a stream with every item refused, then delete(), leaves nothing behind', () async {
      final subscription = await listenToNoItemStream(client, subscriptionId);
      await subscription.cancel();
      // The cancel travels to the worker as a message; this read is answered
      // after the worker has handled it.
      expect((await client.read(intNodeId)).value, 1);

      await expectDeleteLeavesNothingBehind();
    }, timeout: Timeout(Duration(seconds: 30)));

    test('delete() with a stream with every item refused still active leaves nothing behind', () async {
      await listenToNoItemStream(client, subscriptionId);

      await expectDeleteLeavesNothingBehind();
    }, timeout: Timeout(Duration(seconds: 30)));
  });
}
