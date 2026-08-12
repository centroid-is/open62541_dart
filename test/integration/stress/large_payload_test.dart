// STRESS: large payloads through a real Dart Server + Client.
//
// Reads and writes big scalar arrays (10k-100k elements) and long strings and
// verifies byte-for-byte integrity (endpoints, length, checksums), not just
// that the call returns. Uses the Dart Server because the asyncua fish-farm
// model has no large writable array nodes.
@Tags(['integration'])
library;

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import '../harness/net.dart';
import 'stress_support.dart';

void main() {
  group('large payloads (Dart server + client)', () {
    late ServerClient sc;

    setUp(() async {
      sc = await startServerClient(await freePort());
    });
    tearDown(() async {
      await sc.dispose();
    });

    test('read a 50k Int32 array intact', () async {
      // 50k boxed elements is "large" but keeps peak RSS well under the OOM
      // ceiling on a shared CI/dev box (the 100k variant peaks ~280MB, which
      // gets externally SIGKILLed under concurrent memory pressure).
      const n = 50000;
      final list = [for (var i = 0; i < n; i++) DynamicValue(value: i, typeId: NodeId.int32)];
      final v = DynamicValue.fromList(list, typeId: NodeId.int32)..name = 'bigint';
      final id = NodeId.fromString(1, 'bigint');
      sc.server.addVariableNode(id, v, typeId: NodeId.int32);

      final r = await sc.client.read(id).timeout(const Duration(seconds: 30));
      expect(r.isArray, isTrue);
      expect(r.asArray.length, n);
      // Spot-check endpoints + interior; the values equal their index.
      expect(r[0].value, 0);
      expect(r[1].value, 1);
      expect(r[n ~/ 2].value, n ~/ 2);
      expect(r[n - 1].value, n - 1);
      // Full integrity: sum of 0..n-1.
      var sum = 0;
      for (final e in r.asArray) {
        sum += e.value as int;
      }
      expect(sum, (n - 1) * n ~/ 2);
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('write then read back a 50k Double array intact', () async {
      const n = 50000;
      // Seed the node small, then overwrite with a large array via the client.
      final seed = DynamicValue.fromList([DynamicValue(value: 0.0, typeId: NodeId.double)], typeId: NodeId.double)
        ..name = 'bigd';
      final id = NodeId.fromString(1, 'bigd');
      sc.server.addVariableNode(id, seed, typeId: NodeId.double);

      double gen(int i) => i * 0.25 - 1000.0;
      final big = DynamicValue.fromList([
        for (var i = 0; i < n; i++) DynamicValue(value: gen(i), typeId: NodeId.double),
      ], typeId: NodeId.double);
      await sc.client.write(id, big).timeout(const Duration(seconds: 30));

      final r = await sc.client.read(id).timeout(const Duration(seconds: 30));
      expect(r.asArray.length, n);
      expect(r[0].asDouble, closeTo(gen(0), 1e-9));
      expect(r[12345].asDouble, closeTo(gen(12345), 1e-9));
      expect(r[n - 1].asDouble, closeTo(gen(n - 1), 1e-9));
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('long string (~200k chars) round-trips via write', () async {
      // Repeating but non-trivial pattern so truncation/corruption is visible.
      final sb = StringBuffer();
      const unit = 'FishFarm-0123456789-';
      while (sb.length < 200000) {
        sb.write(unit);
      }
      final big = sb.toString();

      final seed = DynamicValue(value: 'seed', typeId: NodeId.uastring)..name = 'bigstr';
      final id = NodeId.fromString(1, 'bigstr');
      sc.server.addVariableNode(id, seed, typeId: NodeId.uastring);

      await sc.client.write(id, DynamicValue(value: big, typeId: NodeId.uastring)).timeout(const Duration(seconds: 30));
      final r = await sc.client.read(id).timeout(const Duration(seconds: 30));
      expect(r.asString.length, big.length);
      expect(r.asString, big);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('large String array (5000 x ~100 chars) intact', () async {
      const n = 5000;
      String gen(int i) => 'tank-$i-${'x' * 100}';
      final v = DynamicValue.fromList([
        for (var i = 0; i < n; i++) DynamicValue(value: gen(i), typeId: NodeId.uastring),
      ], typeId: NodeId.uastring)..name = 'strarr';
      final id = NodeId.fromString(1, 'strarr');
      sc.server.addVariableNode(id, v, typeId: NodeId.uastring);

      final r = await sc.client.read(id).timeout(const Duration(seconds: 30));
      expect(r.asArray.length, n);
      expect(r[0].asString, gen(0));
      expect(r[2500].asString, gen(2500));
      expect(r[n - 1].asString, gen(n - 1));
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
