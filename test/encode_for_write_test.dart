import 'dart:convert';
import 'dart:ffi';
import 'package:open62541_bindings/src/extensions.dart';
import 'package:open62541_bindings/src/library.dart';
import 'package:test/test.dart';
import 'package:binarize/binarize.dart';
import 'package:ffi/ffi.dart';

import 'package:open62541_bindings/src/generated/open62541_bindings.dart'
    as raw;
import 'package:open62541_bindings/src/client.dart';

void main() {
  final lib = Open62541Singleton().lib;
  test('Encode boolean variant', () {
    bool value = true;
    final variant = Client.valueToVariant(value, TypeKindEnum.boolean, lib);
    expect(variant.ref.type, Client.getType(raw.UA_TYPES_BOOLEAN, lib));
    expect(variant.ref.data.cast<Pointer<Bool>>().value.value, value);
    calloc.free(variant);
  });
}
