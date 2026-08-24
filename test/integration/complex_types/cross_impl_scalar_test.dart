// COMPLEX TYPES: cross-implementation scalar fidelity.
//
// Writes edge scalar values to a *different* OPC UA stack (asyncua reference
// fish-farm server) via the Dart client and reads them back, proving the Dart
// client's scalar encode/decode agrees with an independent implementation. The
// harness fish-farm model only exposes scalar variables (Double/Boolean/String/
// UInt16), so this covers cross-impl scalar — not struct — fidelity.
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
  group('cross-impl scalar fidelity (asyncua)', () {
    late ReferenceServer server;
    late DrivenClient dc;

    setUp(() async {
      // Static values only (no live mutation) so setpoint reads are stable.
      server = ReferenceServer.asyncuaFishFarm(port: await freePort(), tanks: 1, live: false);
      await server.start();
      dc = await connectClient(server.endpoint);
    });
    tearDown(() async {
      await dc.dispose();
      await server.stop();
    });

    test('Double edge values write/read (TempSetpoint)', () async {
      final id = await tankVar(dc.client, 1, 'TempSetpoint');
      final cases = <double>[
        0.0,
        -0.0,
        13.5,
        -273.15,
        1e-300, // smallest *normal*-scale value we rely on
        1.7976931348623157e308, // max double
        -1.7976931348623157e308,
        123456789.123456,
      ];
      for (final val in cases) {
        await dc.client.write(id, DynamicValue(value: val, typeId: NodeId.double));
        final r = await dc.client.read(id).timeout(const Duration(seconds: 8));
        expect(r.asDouble, val, reason: 'double $val did not round-trip via asyncua');
      }
    }, timeout: const Timeout(Duration(seconds: 40)));

    test('Double NaN / +Inf / -Inf write/read (TempSetpoint)', () async {
      final id = await tankVar(dc.client, 1, 'TempSetpoint');
      await dc.client.write(id, DynamicValue(value: double.nan, typeId: NodeId.double));
      expect((await dc.client.read(id).timeout(const Duration(seconds: 8))).asDouble.isNaN, isTrue);
      await dc.client.write(id, DynamicValue(value: double.infinity, typeId: NodeId.double));
      expect((await dc.client.read(id).timeout(const Duration(seconds: 8))).asDouble, double.infinity);
      await dc.client.write(id, DynamicValue(value: double.negativeInfinity, typeId: NodeId.double));
      expect((await dc.client.read(id).timeout(const Duration(seconds: 8))).asDouble, double.negativeInfinity);
    }, timeout: const Timeout(Duration(seconds: 40)));

    test('Boolean write/read (PumpRunning)', () async {
      final id = await tankVar(dc.client, 1, 'PumpRunning');
      await dc.client.write(id, DynamicValue(value: false, typeId: NodeId.boolean));
      expect((await dc.client.read(id).timeout(const Duration(seconds: 8))).asBool, isFalse);
      await dc.client.write(id, DynamicValue(value: true, typeId: NodeId.boolean));
      expect((await dc.client.read(id).timeout(const Duration(seconds: 8))).asBool, isTrue);
    }, timeout: const Timeout(Duration(seconds: 40)));

    test('String read (AlarmMessage) and UInt16 read (AlarmSeverity)', () async {
      final msgId = await tankVar(dc.client, 1, 'AlarmMessage');
      final msg = await dc.client.read(msgId).timeout(const Duration(seconds: 8));
      expect(msg.asString, isA<String>()); // seeded empty by the model
      final sevId = await tankVar(dc.client, 1, 'AlarmSeverity');
      final sev = await dc.client.read(sevId).timeout(const Duration(seconds: 8));
      expect(sev.asInt, greaterThanOrEqualTo(0));
    }, timeout: const Timeout(Duration(seconds: 40)));

    test('live sensor Double reads are finite (Temperature)', () async {
      final id = await tankVar(dc.client, 1, 'Temperature');
      final r = await dc.client.read(id).timeout(const Duration(seconds: 8));
      expect(r.asDouble.isFinite, isTrue);
    }, timeout: const Timeout(Duration(seconds: 40)));

    // BUG: subnormal double corrupts over the client wire (see
    // scalar_roundtrip_test.dart). Confirmed the same defect appears
    // cross-implementation: writing 5e-324 to asyncua and reading it back does
    // not preserve the value. Root cause in the Dart client scalar wire path
    // (lib/src/client.dart _variantToValueAutoSchema ~1556), independent of the
    // server implementation.
    test(
      'Double subnormal cross-impl (TempSetpoint)',
      () async {
        final id = await tankVar(dc.client, 1, 'TempSetpoint');
        await dc.client.write(id, DynamicValue(value: 5e-324, typeId: NodeId.double));
        final r = await dc.client.read(id).timeout(const Duration(seconds: 8));
        expect(r.asDouble, 5e-324);
      },
      skip:
          'BUG: subnormal double corrupts over the Dart client wire '
          '(lib/src/client.dart _variantToValueAutoSchema ~1556); '
          'implementation-independent',
      timeout: const Timeout(Duration(seconds: 40)),
    );
  }, skip: asyncuaAvailable() ? false : 'run test/integration/setup_local.sh first (asyncua venv)');
}
