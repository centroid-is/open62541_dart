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
  void testSimpleTypes(dynamic value, TypeKindEnum kind) {
    final variant = Client.valueToVariant(value, kind, lib);
    final decoded = Client.variantToValue(variant);
    expect(decoded, value);
    calloc.free(variant);
  }

  test('Encode boolean variant', () {
    testSimpleTypes(true, TypeKindEnum.boolean);
    testSimpleTypes(false, TypeKindEnum.boolean);
  });

  test('Encode int variant', () {
    testSimpleTypes(10, TypeKindEnum.int16);
    testSimpleTypes(25, TypeKindEnum.uint16);
    testSimpleTypes(1337, TypeKindEnum.int32);
    testSimpleTypes(2556, TypeKindEnum.uint32);
    testSimpleTypes(10516, TypeKindEnum.int64);
    testSimpleTypes(11213, TypeKindEnum.uint64);

    // Test the min and max values of the integer types
    testSimpleTypes(-32768, TypeKindEnum.int16);
    testSimpleTypes(32767, TypeKindEnum.int16);

    testSimpleTypes(0, TypeKindEnum.uint16);
    testSimpleTypes(65535, TypeKindEnum.uint16);

    testSimpleTypes(-2147483648, TypeKindEnum.int32);
    testSimpleTypes(2147483647, TypeKindEnum.int32);

    testSimpleTypes(0, TypeKindEnum.uint32);
    testSimpleTypes(4294967295, TypeKindEnum.uint32);

    testSimpleTypes(0, TypeKindEnum.uint64);
    // There is not a native type in flutter to test this.
    // testSimpleTypes(18446744073709551615, TypeKindEnum.uint64);

    testSimpleTypes(-9223372036854775808, TypeKindEnum.int64);
    testSimpleTypes(9223372036854775807, TypeKindEnum.int64);
  });
  test('Encode float variant', () {
    testSimpleTypes(0.5, TypeKindEnum.float);
    testSimpleTypes(1.5, TypeKindEnum.double);
    testSimpleTypes(-0.5, TypeKindEnum.float);
    testSimpleTypes(-1.5, TypeKindEnum.double);
  });
  test('Encode string variant', () {
    testSimpleTypes("asdfasdf", TypeKindEnum.string);
  });
  test('Encode DateTime variant', () {
    testSimpleTypes(
        DateTime.utc(2025, 10, 5, 18, 30, 150), TypeKindEnum.dateTime);
    testSimpleTypes(
        DateTime.utc(2024, 10, 5, 18, 30, 150), TypeKindEnum.dateTime);
  });
  //TODO: Implement duration
  // test('Encode Duration variant', () {
  //   testSimpleTypes(Duration(milliseconds: 150), TypeKindEnum.);
  // });
}
