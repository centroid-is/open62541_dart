import 'dart:async';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/isolate.dart' show ClientIsolateClosedException;
import 'common.dart';

final unknownNodeId = NodeId.fromString(1, "does.not.exist");

void main() {
  group('ClientIsolate cleanup', () {
    test('delete() should cancel pending connect with clear error', () async {
      final client = await ClientIsolate.create();

      // Start connect to a non-routable IP (RFC 5737 TEST-NET), will hang
      final connectFuture = client.connect('opc.tcp://192.0.2.1:4840');

      // Attach error handler immediately to prevent unhandled async error
      Object? caughtError;
      unawaited(
        connectFuture.then((_) {}).catchError((e) {
          caughtError = e;
        }),
      );

      // Give it a moment to start
      await Future.delayed(const Duration(milliseconds: 100));

      // Delete while connect is pending
      await client.delete();

      // Wait for error propagation
      await Future.delayed(const Duration(milliseconds: 50));

      expect(caughtError, isA<ClientIsolateClosedException>());
    });

    test('delete() should handle read without connection', () async {
      final client = await ClientIsolate.create();

      // Start a read without connecting - this will fail immediately
      // because there's no connection (not hang)
      final readFuture = client.read(NodeId.fromNumeric(0, 2258));

      // Attach error handler immediately
      Object? caughtError;
      unawaited(
        readFuture.then((_) {}).catchError((e) {
          caughtError = e;
        }),
      );

      await Future.delayed(const Duration(milliseconds: 100));

      await client.delete();

      await Future.delayed(const Duration(milliseconds: 50));

      // Should have an error (either from failed read or from delete cancellation)
      expect(caughtError, isNotNull);
    });

    test('delete() should close stream controllers', () async {
      final client = await ClientIsolate.create();

      // Get a state stream (creates a stream controller)
      final stateStream = client.stateStream;
      final streamDone = Completer<void>();

      stateStream.listen((_) {}, onDone: () => streamDone.complete(), onError: (_) {});

      await Future.delayed(const Duration(milliseconds: 100));

      await client.delete();

      // Stream should be closed
      await expectLater(streamDone.future.timeout(const Duration(seconds: 1)), completes);
    });

    test('multiple pending operations should all be cancelled', () async {
      final client = await ClientIsolate.create();

      // Start multiple connect operations to non-routable IPs (will hang)
      final errors = <Object?>[];
      final futures = [
        client.connect('opc.tcp://192.0.2.1:4840'),
        client.connect('opc.tcp://192.0.2.2:4840'),
        client.connect('opc.tcp://192.0.2.3:4840'),
      ];

      for (final future in futures) {
        unawaited(
          future.then((_) {}).catchError((e) {
            errors.add(e);
          }),
        );
      }

      await Future.delayed(const Duration(milliseconds: 100));

      await client.delete();

      // Wait for error propagation
      await Future.delayed(const Duration(milliseconds: 50));

      // All futures should have thrown ClientIsolateClosedException
      expect(errors.length, 3);
      for (final error in errors) {
        expect(error, isA<ClientIsolateClosedException>());
      }
    });
  });

  // Guards the worker race found in the PR #119 review: a stream that ended
  // while the worker was cancelling its streams made delete() fail with
  // "Concurrent modification during iteration", and the worker never deleted
  // its client, so the server kept the session and the subscription.
  group('ClientIsolate cleanup while a stream ends', () {
    late IsolateWatch watch;

    setUpAll(() async => watch = await IsolateWatch.start());
    tearDownAll(() => watch.stop());

    test('delete() with two live streams and a refused create in flight leaves nothing behind', () async {
      final port = await freeTcpPort();
      final server = Server(port: port, logLevel: LogLevel.UA_LOGLEVEL_ERROR);
      server.start();
      addBasicVariables(server);
      final serverTimer = Timer.periodic(Duration(milliseconds: 10), (_) {
        server.runIterate();
      });
      addTearDown(() {
        serverTimer.cancel();
        server.shutdown();
        server.delete();
      });

      final before = await watch.isolates();
      final client = await ClientIsolate.create(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
      final worker = (await watch.isolates()).difference(before).single;
      await client.keepConnected('opc.tcp://127.0.0.1:$port');
      final subscriptionId = await client.subscriptionCreate(requestedPublishingInterval: Duration(milliseconds: 50));

      // The refused create is answered while the worker is cancelling the
      // first live stream, and its stream ends while the worker waits for the
      // second one: that is the stream ending in the middle of the teardown.
      for (final nodeId in [intNodeId, boolNodeId]) {
        client
            .monitoredItems({
              nodeId: [AttributeId.UA_ATTRIBUTEID_VALUE],
            }, subscriptionId)
            .listen((_) {}, onError: (_) {});
      }
      await waitForStats(server, (s) => s.currentMonitoredItemCount == 2, reason: 'two live monitored items');
      client
          .monitoredItems({
            unknownNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE],
          }, subscriptionId)
          .listen((_) {}, onError: (_) {});

      Object? deleteError;
      try {
        await client.delete();
      } catch (e) {
        deleteError = e;
      }
      expect(
        deleteError,
        isNull,
        reason: 'ClientIsolate.delete() must complete without an error when a stream ends during the teardown',
      );
      await watch.expectGone(worker, reason: 'the ClientIsolate worker isolate is still alive after delete()');
      await waitForStats(
        server,
        (s) => s.currentSessionCount == 0 && s.currentSubscriptionCount == 0,
        reason: 'no session and no subscription left on the server after ClientIsolate.delete()',
      );
    }, timeout: Timeout(Duration(seconds: 30)));
  });
}
