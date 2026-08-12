// HMI "Command" scenario.
//
// The feed button on a tank screen calls FeedNow(grams: Double) -> Boolean.
// The server accepts any non-negative amount (returns true) and rejects
// negatives (returns false). We exercise valid and edge arguments and assert
// the returned acceptance flag, plus the missing-argument error path.
@Tags(['integration'])
library;

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import '../harness/browse_resolver.dart';
import '../harness/dart_client.dart';
import '../harness/net.dart';
import '../harness/paths.dart';
import '../harness/reference_server.dart';

void main() {
  group('HMI FeedNow command', () {
    late ReferenceServer server;

    setUp(() async {
      server = ReferenceServer.asyncuaFishFarm(port: await freePort(), tanks: 2, updateMs: 250);
      await server.start();
    });

    tearDown(() async {
      await server.stop();
    });

    for (final kind in clientTypes) {
      test('accepts non-negative feed amounts, rejects negative ($kind)', () async {
        final dc = await connectClient(server.endpoint, kind: kind);
        try {
          final tankId = await resolvePath(dc.client, ['Plant', 'Tank1']);
          final feedId = await tankMethod(dc.client, 1, 'FeedNow');

          Future<bool> feed(double grams) async {
            final res = await dc.client.call(tankId, feedId, [DynamicValue(value: grams, typeId: NodeId.double)]);
            expect(res, hasLength(1), reason: 'FeedNow returns a single accepted flag');
            return res.first.asBool;
          }

          // Valid nominal amount.
          expect(await feed(25.0), isTrue);
          // Boundary: zero is accepted (>= 0).
          expect(await feed(0.0), isTrue);
          // Large amount still accepted.
          expect(await feed(1e9), isTrue);
          // Small positive fraction accepted.
          expect(await feed(0.5), isTrue);
          // Negative amount is rejected.
          expect(await feed(-5.0), isFalse);
          expect(await feed(-0.001), isFalse);
        } finally {
          await dc.dispose();
        }
      }, timeout: const Timeout(Duration(seconds: 60)));

      test('missing argument surfaces an error ($kind)', () async {
        final dc = await connectClient(server.endpoint, kind: kind);
        try {
          final tankId = await resolvePath(dc.client, ['Plant', 'Tank1']);
          final feedId = await tankMethod(dc.client, 1, 'FeedNow');

          // FeedNow requires one Double argument; calling with none must fail
          // rather than silently succeed.
          await expectLater(dc.client.call(tankId, feedId, const []), throwsA(anything));
        } finally {
          await dc.dispose();
        }
      }, timeout: const Timeout(Duration(seconds: 60)));

      test('FeedNow is addressable per tank ($kind)', () async {
        final dc = await connectClient(server.endpoint, kind: kind);
        try {
          for (final tank in [1, 2]) {
            final tankId = await resolvePath(dc.client, ['Plant', 'Tank$tank']);
            final feedId = await tankMethod(dc.client, tank, 'FeedNow');
            final res = await dc.client.call(tankId, feedId, [DynamicValue(value: 10.0, typeId: NodeId.double)]);
            expect(res.first.asBool, isTrue, reason: 'FeedNow on Tank$tank should accept 10g');
          }
        } finally {
          await dc.dispose();
        }
      }, timeout: const Timeout(Duration(seconds: 60)));
    }
  }, skip: asyncuaAvailable() ? false : 'run test/integration/setup_local.sh first');
}
