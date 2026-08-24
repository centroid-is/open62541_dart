// HMI "Multi-screen" scenario.
//
// Several operator panels -- a mix of direct and isolate clients -- run at once
// against the same plant, each subscribing to an overlapping set of tags (as
// real control rooms do). Every panel must get its own healthy, in-range feed
// for every tag it watches, including the tags it shares with other panels.
@Tags(['integration'])
library;

import 'dart:async';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import '../harness/browse_resolver.dart';
import '../harness/dart_client.dart';
import '../harness/net.dart';
import '../harness/paths.dart';
import '../harness/reference_server.dart';
import 'hmi_support.dart';

const _tanks = 4;
const _rate = Duration(milliseconds: 250);

/// One operator panel: a driven client subscribed to a set of tags, collecting
/// per-tag health as data streams in.
class _Panel {
  _Panel(this.name, this.kind, this.tanks);

  final String name;
  final ClientKind kind;
  final List<int> tanks;

  late DrivenClient dc;
  StreamSubscription<Map<NodeId, DynamicValue>>? sub;

  final errors = <Object>[];
  int emissions = 0;
  final changeCounts = <String, int>{};
  final lastValue = <String, double>{};
  final rangeViolations = <String>[];

  Future<void> start(String endpoint) async {
    dc = await connectClient(endpoint, kind: kind);
    final tags = <TagRef>[];
    for (final t in tanks) {
      for (final s in liveSensors) {
        final id = await tankVar(dc.client, t, s);
        tags.add(TagRef('Tank$t/$s', t, s, id));
      }
    }
    final byId = {for (final tag in tags) tag.nodeId: tag};
    for (final tag in tags) {
      changeCounts[tag.label] = 0;
    }

    final subId = await dc.client.subscriptionCreate(requestedPublishingInterval: _rate);
    final stream = dc.client.monitoredItems(valueParam(tags), subId, samplingInterval: _rate);
    sub = stream.listen((map) {
      emissions++;
      for (final entry in map.entries) {
        final tag = byId[entry.key];
        if (tag == null) continue;
        final v = entry.value.asDouble;
        if (!inRange(tag.sensor, v)) rangeViolations.add('$name:${tag.label}=$v');
        final prev = lastValue[tag.label];
        if (prev == null || prev != v) {
          changeCounts[tag.label] = (changeCounts[tag.label] ?? 0) + 1;
        }
        lastValue[tag.label] = v;
      }
    }, onError: errors.add);
  }

  Future<void> stop() async {
    await sub?.cancel();
    await dc.dispose();
  }

  List<String> get watchedTags => changeCounts.keys.toList();
}

void main() {
  group('HMI multi-screen', () {
    late ReferenceServer server;

    setUp(() async {
      server = ReferenceServer.asyncuaFishFarm(port: await freePort(), tanks: _tanks, updateMs: 250);
      await server.start();
    });

    tearDown(() async {
      await server.stop();
    });

    test('four overlapping panels (direct + isolate) all get consistent feeds', () async {
      final panels = <_Panel>[
        _Panel('A', ClientKind.direct, [1, 2]),
        _Panel('B', ClientKind.isolate, [2, 3]),
        _Panel('C', ClientKind.direct, [1, 3, 4]),
        _Panel('D', ClientKind.isolate, [1, 4]),
      ];
      try {
        // Bring every panel online concurrently.
        await Future.wait(panels.map((p) => p.start(server.endpoint)));

        // Let the plant run under the full panel load.
        await Future<void>.delayed(const Duration(seconds: 6));

        for (final p in panels) {
          await p.sub?.cancel();
        }

        // Per-panel health.
        for (final p in panels) {
          expect(p.errors, isEmpty, reason: 'panel ${p.name} had stream errors: ${p.errors}');
          expect(
            p.emissions,
            greaterThanOrEqualTo(10),
            reason: 'panel ${p.name} received too few emissions (${p.emissions})',
          );
          expect(p.rangeViolations, isEmpty, reason: 'panel ${p.name} out-of-range: ${p.rangeViolations}');
          for (final tag in p.watchedTags) {
            expect(p.lastValue.containsKey(tag), isTrue, reason: 'panel ${p.name} never got a value for $tag');
            expect(
              p.changeCounts[tag],
              greaterThanOrEqualTo(3),
              reason: 'panel ${p.name} tag $tag updated only ${p.changeCounts[tag]} times',
            );
          }
        }

        // Cross-panel consistency: for every tag watched by more than one panel,
        // all panels observed live, in-range values for it. (Exact values differ
        // by sampling phase, but they must share the same sensor band.)
        final tagToPanels = <String, List<_Panel>>{};
        for (final p in panels) {
          for (final tag in p.watchedTags) {
            (tagToPanels[tag] ??= []).add(p);
          }
        }
        final shared = tagToPanels.entries.where((e) => e.value.length > 1).toList();
        expect(shared, isNotEmpty, reason: 'expected overlapping tags across panels');
        for (final e in shared) {
          final sensor = e.key.split('/').last;
          for (final p in e.value) {
            final v = p.lastValue[e.key]!;
            expect(inRange(sensor, v), isTrue, reason: 'shared tag ${e.key} on panel ${p.name} out of band: $v');
          }
        }
      } finally {
        for (final p in panels) {
          await p.stop();
        }
      }
    }, timeout: const Timeout(Duration(seconds: 120)));
  }, skip: asyncuaAvailable() ? false : 'run test/integration/setup_local.sh first');
}
