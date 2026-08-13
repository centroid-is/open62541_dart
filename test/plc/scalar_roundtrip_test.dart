// Scalar read/write fidelity against every configured controller, over ONE
// shared session (setUpAll/tearDownAll) to respect the tiny session table.
@Tags(['plc'])
library;

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'plc_config.dart';
import 'plc_fixture.dart';
import 'plc_session.dart';

void main() {
  final targets = PlcConfig.configured();
  tearDownAll(PlcSession.shutdownEmulators);

  if (targets.isEmpty) {
    test('no PLCs configured', () {}, skip: 'Set PLC_<X>_URL (or =emulator).');
    return;
  }

  for (final cfg in targets) {
    group('scalars [${cfg.name}]', () {
      late PlcSession s;
      setUpAll(() async => s = await PlcSession.open(cfg));
      tearDownAll(() async => s.dispose());

      for (final v in PlcFixture.scalars) {
        test('${v.name} round-trips both values', () async {
          final node = await s.node(v.name);
          for (final want in [v.writeA, v.writeB]) {
            await s.client.write(node, DynamicValue(value: want, typeId: v.typeId));
            final got = (await s.client.read(node)).value;
            if (v.tolerance > 0) {
              expect((got as num).toDouble(), closeTo((want as num).toDouble(), v.tolerance.toDouble()));
            } else {
              expect(got, want, reason: '${v.name}: wrote $want got $got');
            }
          }
        });
      }

      test('Counter is live and monotonic', () async {
        final node = await s.node(PlcFixture.counterName);
        final a = (await s.client.read(node)).asInt;
        await Future<void>.delayed(const Duration(milliseconds: 600));
        final b = (await s.client.read(node)).asInt;
        expect(b, greaterThan(a), reason: 'the PLC must increment Counter');
      });

      test('TestArray round-trips', () async {
        final node = await s.node(PlcFixture.arrayName);
        final want = [for (var i = 0; i < PlcFixture.arrayLength; i++) (i + 1) * 111];
        await s.client.write(node, DynamicValue.fromList(want, typeId: PlcFixture.arrayTypeId));
        final got = await s.client.read(node);
        expect(got.isArray, isTrue);
        expect([for (var i = 0; i < PlcFixture.arrayLength; i++) got[i].asInt], want);
      });
    });
  }
}
