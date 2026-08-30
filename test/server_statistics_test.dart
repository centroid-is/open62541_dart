import 'package:test/test.dart';

import 'package:open62541/open62541.dart';

import 'common.dart';

/// Polls [predicate] against a fresh [Server.statistics] snapshot until it
/// holds (returning the matching snapshot) or [timeout] expires (failing the
/// test with the last snapshot in the message).
Future<ServerStatistics> waitForStats(
  Server server,
  bool Function(ServerStatistics stats) predicate, {
  Duration timeout = const Duration(seconds: 10),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  ServerStatistics stats = server.statistics;
  while (!predicate(stats)) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for ${reason ?? 'statistics condition'}; last: $stats');
    }
    await Future.delayed(const Duration(milliseconds: 50));
    stats = server.statistics;
  }
  return stats;
}

void main() {
  group('Server statistics', () {
    late int port;
    late Server server;

    setUp(() async {
      port = await freeTcpPort();
      server = setupServer(port);
      addBasicVariables(server);
    });

    tearDown(() {
      server.shutdown();
      server.delete();
    });

    test('sessions, subscriptions and monitored items are counted live', () async {
      // Fresh server: nothing connected yet.
      final initial = server.statistics;
      expect(initial.currentSessionCount, 0);
      expect(initial.currentChannelCount, 0);
      // Diagnostics nodes are present in this build, so the subscription
      // counters must be available (not null).
      expect(initial.currentSubscriptionCount, 0);
      expect(initial.cumulatedSubscriptionCount, 0);
      expect(initial.currentMonitoredItemCount, 0);

      // Two clients connect -> two sessions (and at least two secure channels).
      final client1 = await setupClient(port);
      final client2 = await setupClient(port);
      final connected = await waitForStats(
        server,
        (s) => s.currentSessionCount == 2,
        reason: 'currentSessionCount == 2',
      );
      expect(connected.cumulatedSessionCount, greaterThanOrEqualTo(2));
      expect(connected.currentChannelCount, greaterThanOrEqualTo(2));

      // A subscription with one monitored item is reflected in the counters.
      final subId = await client1.subscriptionCreate();
      final monitored = client1
          .monitoredItems({
            intNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE],
          }, subId)
          .listen((_) {}, onError: (_) {});
      await waitForStats(
        server,
        (s) => s.currentSubscriptionCount == 1 && s.currentMonitoredItemCount == 1,
        reason: 'one subscription with one monitored item',
      );
      expect(server.statistics.cumulatedSubscriptionCount, greaterThanOrEqualTo(1));

      // Tearing the monitored item down empties the monitored-item counter.
      await monitored.cancel();
      await waitForStats(server, (s) => s.currentMonitoredItemCount == 0, reason: 'monitored items back to 0');

      // Disconnecting drops the session counts again.
      await client2.delete();
      await waitForStats(server, (s) => s.currentSessionCount == 1, reason: 'currentSessionCount == 1');
      await client1.delete();
      final drained = await waitForStats(server, (s) => s.currentSessionCount == 0, reason: 'currentSessionCount == 0');
      // Subscriptions died with their session.
      expect(drained.currentSubscriptionCount, 0);
      expect(drained.cumulatedSessionCount, greaterThanOrEqualTo(2));
    });
  });
}
