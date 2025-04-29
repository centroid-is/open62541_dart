import 'package:test/test.dart';
import 'package:open62541/src/generated/open62541_bindings.dart';
import 'dart:ffi';

void main() {
  test("Verify sizes", () {
    expect(sizeOf<UA_ClientConfig>(), 864);
  });
}
