import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart';

void main() {
  group('Server statistics', () {
    late int port;
    late Server server;

    setUp(() async {
      server = setupServer();
      port = server.port;
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
      // No subscription yet -> nothing delivered, but the counters are
      // available (0, not null) because the diagnostics array reads fine.
      expect(initial.liveDataChangeNotificationCount, 0);
      expect(initial.liveNotificationCount, 0);

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

      // Every data change the server publishes is counted, summed over the
      // live subscriptions: write the monitored node a few times and the
      // data-change counter climbs (the all-notifications counter, data
      // changes + events, is at least as large).
      for (var i = 1; i <= 3; i++) {
        server.write(intNodeId, DynamicValue(value: 100 + i, typeId: NodeId.int32));
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      final published = await waitForStats(
        server,
        (s) => (s.liveDataChangeNotificationCount ?? 0) >= 1,
        reason: 'data-change notifications counted',
      );
      expect(published.liveNotificationCount, greaterThanOrEqualTo(published.liveDataChangeNotificationCount!));

      // Tearing the monitored item down empties the monitored-item counter.
      await monitored.cancel();
      await waitForStats(server, (s) => s.currentMonitoredItemCount == 0, reason: 'monitored items back to 0');

      // Disconnecting drops the session counts again.
      await client2.delete();
      await waitForStats(server, (s) => s.currentSessionCount == 1, reason: 'currentSessionCount == 1');
      await client1.delete();
      final drained = await waitForStats(server, (s) => s.currentSessionCount == 0, reason: 'currentSessionCount == 0');
      // Subscriptions died with their session — and took their notification
      // counts with them: the sums cover LIVE subscriptions only, which is
      // why the fields are `live…`, not `cumulated…`.
      expect(drained.currentSubscriptionCount, 0);
      expect(drained.liveDataChangeNotificationCount, 0);
      expect(drained.liveNotificationCount, 0);
      expect(drained.cumulatedSessionCount, greaterThanOrEqualTo(2));
    });
  });
}
