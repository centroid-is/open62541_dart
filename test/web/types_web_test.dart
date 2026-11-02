@TestOn('browser')
library;

// The point of `open62541_types.dart` is that it has no `dart:ffi` anywhere in
// its transitive imports. That is not a property you can assert from the VM —
// a stray `import 'node_id.dart'` in dynamic_value.dart compiles perfectly
// there and only fails when someone tries `flutter build web` months later.
//
// So this file exists to be *compiled*: if the barrel ever reaches `dart:ffi`
// again, this test stops building and the lane goes red. The assertions below
// are a bonus — they also pin the behaviour dart2js is known to get wrong
// (32-bit integer semantics, and `1` being indistinguishable from `1.0`).

import 'package:test/test.dart';

import 'package:open62541/open62541_types.dart';

void main() {
  test('the barrel is reachable from a browser at all', () {
    // If this file compiled, the property under test already holds.
    expect(NodeId.rootFolder.numeric, 84);
    expect(NodeId.rootFolder.namespace, 0);
  });

  group('NodeId round-trips its three identifier kinds', () {
    test('string', () {
      final id = NodeId.fromString(2, 'MAIN.CN01.Motor');
      expect(id.isString(), isTrue);
      expect(id.string, 'MAIN.CN01.Motor');
      expect(id.toString(), 'ns=2;s=MAIN.CN01.Motor');
      expect(NodeId.from(id), id);
    });

    test('numeric', () {
      final id = NodeId.fromNumeric(0, 2258);
      expect(id.isNumeric(), isTrue);
      expect(id.numeric, 2258);
      expect(id.toString(), 'ns=0;i=2258');
      expect(NodeId.from(id), id);
    });

    test('guid, lowercased', () {
      final id = NodeId.fromGuid(1, '09087E75-8E5E-499B-954F-F2A9603DB28A');
      expect(id.isGuid(), isTrue);
      expect(id.guid, '09087e75-8e5e-499b-954f-f2a9603db28a');
      expect(id.toString(), 'ns=1;g=09087e75-8e5e-499b-954f-f2a9603db28a');
      expect(NodeId.from(id), id);
    });

    test('a malformed guid is refused rather than stored', () {
      expect(() => NodeId.fromGuid(1, 'not-a-guid'), throwsA(anything));
    });
  });

  test('equality and hashCode separate the identifier kinds', () {
    // ns=0;i=1 and ns=0;s="1" are different nodes; on a backend where every
    // number is a double, a sloppier equality could conflate them.
    expect(NodeId.fromNumeric(0, 1), isNot(NodeId.fromString(0, '1')));
    expect(NodeId.fromNumeric(0, 1), NodeId.fromNumeric(0, 1));
    expect(NodeId.fromNumeric(0, 1).hashCode, NodeId.fromNumeric(0, 1).hashCode);
    expect(NodeId.fromNumeric(1, 1), isNot(NodeId.fromNumeric(0, 1)));
  });

  test('a NodeId identifier above 2^32 survives dart2js', () {
    // Numeric NodeIds are UInt32 in the spec, so this is defensive rather than
    // load-bearing — but it is the exact shape of bug that bit newUlid(), and
    // it costs one assertion to know it is not present here.
    final big = NodeId.fromNumeric(0, 0x1FFFFFFFF);
    expect(big.numeric, 0x1FFFFFFFF);
    expect(big.toString(), 'ns=0;i=8589934591');
  });

  group('DynamicValue carries values through a browser', () {
    test('scalars', () {
      expect(DynamicValue(value: 42).asInt, 42);
      expect(DynamicValue(value: 'hi').asString, 'hi');
      expect(DynamicValue(value: true).asBool, isTrue);
      expect(DynamicValue(value: 1.5).asDouble, 1.5);
    });

    test('a named struct keeps its fields and its typeId', () {
      final v = DynamicValue(typeId: NodeId.fromString(2, 'ST_Motor'))
        ..['run'] = DynamicValue(value: true)
        ..['speed'] = DynamicValue(value: 1450);
      expect(v['run'].asBool, isTrue);
      expect(v['speed'].asInt, 1450);
      expect(v.typeId, NodeId.fromString(2, 'ST_Motor'));
    });

    test('a list keeps its order', () {
      final v = DynamicValue.fromList([DynamicValue(value: 1), DynamicValue(value: 2)]);
      expect(v.asArray.length, 2);
      expect(v.asArray.first.asInt, 1);
    });
  });
}
