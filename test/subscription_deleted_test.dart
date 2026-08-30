// Test that the subscription deleteCallback fires when the server deletes
// a subscription due to lifetime expiry.
//
// Strategy: pause the client's runIterate so it stops replenishing
// publish requests. The server exhausts outstanding requests, the
// subscription lifetime expires, and the server deletes it. When
// we resume runIterate, the client sends a new publish request,
// gets BadNoSubscription, and the C layer fires deleteCallback.

import 'dart:async';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';

import 'common.dart' show freeTcpPort;

final intNodeId = NodeId.fromString(1, "the.int");

void main() {
  late int serverPort;

  late Server server;
  late Client client;
  late Timer serverTimer;
  Timer? clientTimer;

  setUp(() async {
    serverPort = await freeTcpPort();
    server = Server(port: serverPort, logLevel: LogLevel.UA_LOGLEVEL_WARNING);
    server.start();

    DynamicValue intValue = DynamicValue(value: 0, typeId: NodeId.int32, name: "the.int");
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

  test('SubscriptionDeleted error fires when server-side subscription expires', () async {
    // Very short-lived subscription:
    //   publishingInterval = 10ms
    //   maxKeepAliveCount  = 1  → keepAlive every 10ms
    //   lifetimeCount      = 3  → lifetime = 30ms after last publish request
    //
    // With 10 outstanding publish requests (default), the server
    // exhausts them in ~100ms, then the subscription expires ~30ms later.
    // Total: ~130ms of client silence kills the subscription.
    final subscriptionId = await client.subscriptionCreate(
      requestedPublishingInterval: Duration(milliseconds: 10),
      requestedLifetimeCount: 3,
      requestedMaxKeepAliveCount: 1,
    );

    final stream = client.monitor(intNodeId, subscriptionId, samplingInterval: Duration(milliseconds: 10));

    final values = <int>[];
    final errors = <Object>[];
    final deletedCompleter = Completer<void>();

    final sub = stream.listen(
      (event) => values.add(event.value as int),
      onError: (error) {
        errors.add(error);
        if (error is SubscriptionDeleted && !deletedCompleter.isCompleted) {
          deletedCompleter.complete();
        }
      },
    );

    // Confirm subscription works
    await Future.delayed(Duration(milliseconds: 500));
    expect(values, isNotEmpty, reason: 'Should have received initial value');

    // === PAUSE CLIENT ===
    // Stop runIterate so the client doesn't replenish publish requests.
    // The server will exhaust the outstanding requests and delete
    // the subscription when its lifetime expires.
    print('Pausing client runIterate...');
    clientTimer?.cancel();
    clientTimer = null;

    // Wait long enough for server to exhaust outstanding publish
    // requests and delete the subscription.
    // 10 outstanding × 10ms keepAlive + 30ms lifetime + margin = ~2s
    await Future.delayed(Duration(seconds: 2));

    // === RESUME CLIENT ===
    // The client will process pending data and send new publish requests.
    // The server responds with BadNoSubscription → deleteCallback fires.
    print('Resuming client runIterate...');
    clientTimer = Timer.periodic(Duration(milliseconds: 10), (_) {
      client.runIterate(Duration(milliseconds: 10));
    });

    await deletedCompleter.future.timeout(
      Duration(seconds: 10),
      onTimeout: () => fail('SubscriptionDeleted error never fired on monitor stream'),
    );
    print('SubscriptionDeleted detected!');

    expect(
      errors.whereType<SubscriptionDeleted>(),
      isNotEmpty,
      reason: 'Should have received SubscriptionDeleted error',
    );

    await sub.cancel();
  }, timeout: Timeout(Duration(seconds: 30)));

  test('SubscriptionDeleted fires for each subscription when multiple exist', () async {
    // Create two independent subscriptions with short lifetimes
    final subId1 = await client.subscriptionCreate(
      requestedPublishingInterval: Duration(milliseconds: 10),
      requestedLifetimeCount: 3,
      requestedMaxKeepAliveCount: 1,
    );
    final subId2 = await client.subscriptionCreate(
      requestedPublishingInterval: Duration(milliseconds: 10),
      requestedLifetimeCount: 3,
      requestedMaxKeepAliveCount: 1,
    );

    expect(subId1, isNot(equals(subId2)), reason: 'Should get distinct subscription IDs');

    final stream1 = client.monitor(intNodeId, subId1, samplingInterval: Duration(milliseconds: 10));
    final stream2 = client.monitor(intNodeId, subId2, samplingInterval: Duration(milliseconds: 10));

    final deleted1 = Completer<int>();
    final deleted2 = Completer<int>();

    final sub1 = stream1.listen(
      (_) {},
      onError: (error) {
        if (error is SubscriptionDeleted && !deleted1.isCompleted) {
          deleted1.complete(error.subscriptionId);
        }
      },
    );
    final sub2 = stream2.listen(
      (_) {},
      onError: (error) {
        if (error is SubscriptionDeleted && !deleted2.isCompleted) {
          deleted2.complete(error.subscriptionId);
        }
      },
    );

    // Confirm both subscriptions are working
    await Future.delayed(Duration(milliseconds: 500));

    // Pause → both subscriptions expire → resume
    clientTimer?.cancel();
    clientTimer = null;
    await Future.delayed(Duration(seconds: 2));

    clientTimer = Timer.periodic(Duration(milliseconds: 10), (_) {
      client.runIterate(Duration(milliseconds: 10));
    });

    final result1 = await deleted1.future.timeout(
      Duration(seconds: 10),
      onTimeout: () => fail('SubscriptionDeleted never fired for sub 1'),
    );
    final result2 = await deleted2.future.timeout(
      Duration(seconds: 10),
      onTimeout: () => fail('SubscriptionDeleted never fired for sub 2'),
    );

    expect(result1, equals(subId1), reason: 'Sub 1 should get its own subscription ID');
    expect(result2, equals(subId2), reason: 'Sub 2 should get its own subscription ID');

    await sub1.cancel();
    await sub2.cancel();
  }, timeout: Timeout(Duration(seconds: 30)));
}
