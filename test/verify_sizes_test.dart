import 'package:ffi/ffi.dart';
import 'package:test/test.dart';
import 'package:open62541/src/generated/open62541_bindings.dart';
import 'dart:ffi';
import 'package:open62541/open62541.dart';

void main() {
  final lib = Open62541Singleton().lib;
  test("Verify sizes", () {
    expect(sizeOf<UA_ClientConfig>(), 864);
    expect(sizeOf<UA_DataType>(), 72);
    print(Client.getType(UaTypes.readRequest, lib).ref.typeName.cast<Utf8>().toDartString());
  });
}
