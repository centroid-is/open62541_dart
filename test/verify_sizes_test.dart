import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/common.dart';
import 'package:open62541/src/generated/open62541_bindings.dart' as raw;

void main() {
  final lib = raw.open62541(loadOpen62541Library(local: true));
  test("Verify sizes", () {
    expect(sizeOf<raw.UA_ClientConfig>(), 864);
    expect(sizeOf<raw.UA_DataType>(), 72);
  });
  test("Verify types", () {
    expect(getType(UaTypes.readRequest, lib).ref.typeName.cast<Utf8>().toDartString(), "ReadRequest");
    expect(getType(UaTypes.readResponse, lib).ref.typeName.cast<Utf8>().toDartString(), "ReadResponse");
    expect(getType(UaTypes.boolean, lib).ref.typeName.cast<Utf8>().toDartString(), "Boolean");
  });
}
