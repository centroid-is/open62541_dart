import 'package:test/test.dart';

import 'package:open62541/src/node_id.dart';

void main() {
  test('Nodeid comparitor test', () {
    final a = NodeId.int64;
    final b = NodeId.uastring;
    expect(a, isNot(b));
  });

  test('GUID NodeId round trip', () {
    final a = NodeId.fromGuid(1, '09087E75-8E5E-499B-954F-F2A9603DB28A');
    expect(a.isGuid(), isTrue);
    expect(a.isNumeric(), isFalse);
    expect(a.isString(), isFalse);
    // Canonicalized to lowercase.
    expect(a.guid, '09087e75-8e5e-499b-954f-f2a9603db28a');
    expect(a.toString(), 'ns=1;g=09087e75-8e5e-499b-954f-f2a9603db28a');

    // Equality/hash semantics.
    expect(a, NodeId.fromGuid(1, '09087e75-8e5e-499b-954f-f2a9603db28a'));
    expect(a.hashCode, NodeId.fromGuid(1, a.guid).hashCode);
    expect(a, isNot(NodeId.fromGuid(2, a.guid)));
    expect(NodeId.from(a), a);

    // Raw round trip preserves every byte of the GUID.
    final rawId = a.toRaw();
    expect(NodeId.fromRaw(rawId), a);

    expect(() => NodeId.fromGuid(1, 'not-a-guid'), throwsA(anything));
  });
}
