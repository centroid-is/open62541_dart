// Structured-type (struct) fidelity against controllers that support complex
// types (TwinCAT, M262). The M240 is skipped (flat symbols only).
@Tags(['plc'])
library;

import 'package:test/test.dart';

import 'plc_config.dart';
import 'plc_fixture.dart';
import 'plc_session.dart';

void main() {
  final targets = PlcConfig.configured().where((c) => c.supportsComplexTypes).toList();
  tearDownAll(PlcSession.shutdownEmulators);

  if (PlcConfig.configured().isEmpty) {
    test('no PLCs configured', () {}, skip: 'Set PLC_<X>_URL (or =emulator).');
    return;
  }
  if (targets.isEmpty) {
    test('no complex-type PLC configured', () {}, skip: 'Configure TwinCAT or M262 for struct tests.');
    return;
  }

  for (final cfg in targets) {
    group('struct [${cfg.name}]', () {
      late PlcSession s;
      setUpAll(() async => s = await PlcSession.open(cfg));
      tearDownAll(() async => s.dispose());

      test('TestStruct reads as an object with all fields', () async {
        final v = await s.client.read(await s.node(PlcFixture.structName));
        expect(v.isObject, isTrue, reason: 'struct must decode as an object');
        for (final f in PlcFixture.structFields) {
          expect(v.contains(f.name), isTrue, reason: 'missing field ${f.name}');
        }
      });

      test('TestStruct round-trips a modified value', () async {
        final node = await s.node(PlcFixture.structName);
        final v = await s.client.read(node);
        // Mutate every field to a known value.
        v['Id'] = 4242;
        v['Value'] = 8.75;
        v['Enabled'] = true;
        v['Label'] = 'basin-7';
        await s.client.write(node, v);

        final back = await s.client.read(node);
        expect(back['Id'].asInt, 4242);
        expect(back['Value'].asDouble, closeTo(8.75, 1e-3));
        expect(back['Enabled'].asBool, isTrue);
        expect(back['Label'].asString, 'basin-7');
      });
    });
  }
}
