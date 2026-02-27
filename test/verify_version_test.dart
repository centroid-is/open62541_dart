import 'package:test/test.dart';

import 'package:open62541/open62541.dart';

void main() {
  test('Verify version', () {
    expect(UA_OPEN62541_VERSION, "v1.5.2");
  });
}
