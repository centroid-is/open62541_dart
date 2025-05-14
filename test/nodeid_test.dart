import 'package:test/test.dart';

import 'package:open62541/src/node_id.dart';

void main() {
  test('Nodeid comparitor test', () {
    final a = NodeId.int64;
    final b = NodeId.uastring;
    expect(a, isNot(b));
  });
}
