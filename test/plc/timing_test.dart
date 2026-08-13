// Timing + accuracy against every configured controller, over ONE shared
// session. Measures read/write round-trip latency (reports min/avg/p95/max) and
// verifies value accuracy under repetition. Upper bounds are lenient so real
// hardware over a plant network doesn't flake; override with PLC_TIMING_MAX_MS.
@Tags(['plc'])
library;

import 'dart:io';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'plc_config.dart';
import 'plc_fixture.dart';
import 'plc_session.dart';

int get _maxMs => int.tryParse(Platform.environment['PLC_TIMING_MAX_MS'] ?? '') ?? 3000;

void main() {
  final targets = PlcConfig.configured();
  tearDownAll(PlcSession.shutdownEmulators);

  if (targets.isEmpty) {
    test('no PLCs configured', () {}, skip: 'Set PLC_<X>_URL (or =emulator).');
    return;
  }

  for (final cfg in targets) {
    group('timing [${cfg.name}]', () {
      late PlcSession s;
      setUpAll(() async => s = await PlcSession.open(cfg));
      tearDownAll(() async => s.dispose());

      test('read latency + accuracy (Setpoint)', () async {
        final node = await s.node(PlcFixture.setpoint.name);
        await s.client.write(node, DynamicValue(value: 12.5, typeId: NodeId.float));
        final samples = <int>[];
        for (var i = 0; i < 50; i++) {
          final sw = Stopwatch()..start();
          final v = await s.client.read(node);
          sw.stop();
          samples.add(sw.elapsedMicroseconds);
          expect(v.asDouble, closeTo(12.5, 1e-3)); // accuracy under repetition
        }
        _report('${cfg.name} read', samples);
        expect(_avgMs(samples), lessThan(_maxMs));
      });

      test('write latency (Setpoint)', () async {
        final node = await s.node(PlcFixture.setpoint.name);
        final samples = <int>[];
        for (var i = 0; i < 50; i++) {
          final sw = Stopwatch()..start();
          await s.client.write(node, DynamicValue(value: i.toDouble(), typeId: NodeId.float));
          sw.stop();
          samples.add(sw.elapsedMicroseconds);
        }
        _report('${cfg.name} write', samples);
        expect(_avgMs(samples), lessThan(_maxMs));
      });

      test('complex-type read latency + fidelity', () async {
        if (!cfg.supportsComplexTypes) {
          markTestSkipped('${cfg.name} has no structured types');
          return;
        }
        final node = await s.node(PlcFixture.structName);
        final samples = <int>[];
        for (var i = 0; i < 30; i++) {
          final sw = Stopwatch()..start();
          final v = await s.client.read(node);
          sw.stop();
          samples.add(sw.elapsedMicroseconds);
          // Fidelity: every field is present and typed correctly each time.
          expect(v.isObject, isTrue);
          expect(v['Id'].asInt, isNotNull);
          expect(v['Value'].asDouble, isNotNull);
        }
        _report('${cfg.name} struct read', samples);
        expect(_avgMs(samples), lessThan(_maxMs));
      });
    });
  }
}

double _avgMs(List<int> micros) => micros.reduce((a, b) => a + b) / micros.length / 1000.0;

void _report(String label, List<int> micros) {
  final sorted = [...micros]..sort();
  double ms(int i) => sorted[i] / 1000.0;
  final p95 = sorted[(sorted.length * 0.95).floor().clamp(0, sorted.length - 1)];
  // ignore: avoid_print
  print(
    '[$label] n=${micros.length} min=${ms(0).toStringAsFixed(2)} '
    'avg=${_avgMs(micros).toStringAsFixed(2)} p95=${(p95 / 1000).toStringAsFixed(2)} '
    'max=${ms(sorted.length - 1).toStringAsFixed(2)} ms',
  );
}
