import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart';

/// Bit-exact comparison for doubles (so NaN and -0.0 are handled correctly).
Matcher bitEquals(double expected) => predicate<Object?>((actual) {
  if (actual is! num) return false;
  final a = ByteData(8)..setFloat64(0, actual.toDouble());
  final b = ByteData(8)..setFloat64(0, expected);
  return a.getUint64(0) == b.getUint64(0);
}, 'has the same 64-bit representation as $expected');

/// Round a double to the nearest float32-representable double.
double asFloat32(double v) => (ByteData(8)..setFloat32(0, v)).getFloat32(0);

void main() {
  const port = 4855;
  late Server server;
  late Client client;

  final doubleNode = NodeId.fromString(1, 'the.subnormal.double');
  final floatNode = NodeId.fromString(1, 'the.subnormal.float');

  setUpAll(() async {
    server = setupServer(port);
    server.addVariableNode(doubleNode, DynamicValue(value: 0.0, typeId: NodeId.double, name: 'the.subnormal.double'));
    server.addVariableNode(floatNode, DynamicValue(value: 0.0, typeId: NodeId.float, name: 'the.subnormal.float'));
    client = await setupClient(port);
  });

  tearDownAll(() async {
    client.disconnect();
    await client.delete();
    server.shutdown();
    // Give the setupServer runIterate loop a moment to observe the shutdown
    // and stop before we delete the server.
    await Future.delayed(const Duration(milliseconds: 100));
    server.delete();
  });

  Future<double> roundTripDouble(double v) async {
    await client.write(doubleNode, DynamicValue(value: v, typeId: NodeId.double));
    final result = await client.read(doubleNode);
    return (result.value as num).toDouble();
  }

  Future<double> roundTripFloat(double v) async {
    await client.write(floatNode, DynamicValue(value: v, typeId: NodeId.float));
    final result = await client.read(floatNode);
    return (result.value as num).toDouble();
  }

  group('Double round-trip through client', () {
    final cases = <String, double>{
      'smallest positive subnormal': 5e-324,
      'mid subnormal': 1.5e-310,
      'largest subnormal': 2.225073858507201e-308,
      'smallest normal': 2.2250738585072014e-308,
      'normal control': 3.14159265358979,
      'zero': 0.0,
    };
    cases.forEach((name, value) {
      test(name, () async {
        expect(await roundTripDouble(value), bitEquals(value));
      });
    });

    test('NaN control', () async {
      expect((await roundTripDouble(double.nan)).isNaN, isTrue);
    });
    test('+Inf control', () async {
      expect(await roundTripDouble(double.infinity), equals(double.infinity));
    });
    test('-Inf control', () async {
      expect(await roundTripDouble(double.negativeInfinity), equals(double.negativeInfinity));
    });
  });

  group('Float round-trip through client', () {
    // Values that are exactly representable as float32.
    final cases = <String, double>{
      'smallest positive subnormal': asFloat32(1.401298464324817e-45),
      'mid subnormal': asFloat32(5.877471754111438e-39),
      'largest subnormal': asFloat32(1.1754942106924411e-38),
      'smallest normal': asFloat32(1.1754943508222875e-38),
      'normal control': asFloat32(3.5),
      'zero': 0.0,
    };
    cases.forEach((name, value) {
      test(name, () async {
        expect(await roundTripFloat(value), bitEquals(value));
      });
    });

    test('+Inf control', () async {
      expect(await roundTripFloat(double.infinity), equals(double.infinity));
    });
    test('-Inf control', () async {
      expect(await roundTripFloat(double.negativeInfinity), equals(double.negativeInfinity));
    });
  });
}
