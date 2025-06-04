import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

import 'package:open62541/src/extensions.dart';
import 'package:open62541/src/generated/open62541_bindings.dart' as raw;

void main() {
  test('UA_DataType', () {
    final a = calloc<raw.UA_DataType>();
    a.ref.membersSize = 1;
    a.ref.memSize = 15;
    a.ref.typeKind = raw.UA_DataTypeKind.UA_DATATYPEKIND_STRUCTURE;
    expect(a.ref.membersSize, 1);
    expect(a.ref.memSize, 15);
    expect(a.ref.typeKind, raw.UA_DataTypeKind.UA_DATATYPEKIND_STRUCTURE);
    a.ref.memSize = 10;
    a.ref.membersSize = 10;
    a.ref.typeKind = raw.UA_DataTypeKind.UA_DATATYPEKIND_NODEID;
    expect(a.ref.memSize, 10);
    expect(a.ref.membersSize, 10);
    expect(a.ref.typeKind, raw.UA_DataTypeKind.UA_DATATYPEKIND_NODEID);
    a.ref.memSize = 16500;
    a.ref.membersSize = 25;
    a.ref.typeKind = raw.UA_DataTypeKind.UA_DATATYPEKIND_OPTSTRUCT;
    expect(a.ref.memSize, 16500);
    expect(a.ref.membersSize, 25);
    expect(a.ref.typeKind, raw.UA_DataTypeKind.UA_DATATYPEKIND_OPTSTRUCT);
    calloc.free(a);
  });
}
