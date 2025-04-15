import 'dart:collection';
import 'dart:convert';
import 'dart:ffi';
import 'package:open62541_bindings/dynamic_value.dart';
import 'package:open62541_bindings/src/extensions.dart';
import 'package:open62541_bindings/src/library.dart';
import 'package:open62541_bindings/src/nodeId.dart';
import 'package:open62541_bindings/src/types/create_type.dart';
import 'package:open62541_bindings/src/types/schema.dart';
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
    if (value is List) {
      expect(decoded is List, true);
      expect(decoded.length, value.length);
      for (int i = 0; i < value.length; i++) {
        if (value[i] is double) {
          expect(decoded[i], closeTo(value[i], 1e-5));
        } else {
          expect(decoded[i], value[i]);
        }
      }
    } else {
      if (value is double) {
        expect(decoded, closeTo(value, 1e-5));
      } else {
        expect(decoded, value);
      }
    }
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

  test('Encode arrays variant', () {
    var values = [false, false, true, true];
    testSimpleTypes(values, TypeKindEnum.boolean);

    var uintValues = [15, 25, 26, 27, 32, 99];
    var intValues = [15, 25, 26, 27, 32, 99, -11, -25, -99];
    testSimpleTypes(intValues, TypeKindEnum.int16);
    testSimpleTypes(intValues, TypeKindEnum.int32);
    testSimpleTypes(intValues, TypeKindEnum.int64);

    testSimpleTypes(uintValues, TypeKindEnum.uint16);
    testSimpleTypes(uintValues, TypeKindEnum.uint32);
    testSimpleTypes(uintValues, TypeKindEnum.uint64);

    var floatValues = [15.34, 25.12, 26.77, 27.82, 32.1, 99.0, -14.32];
    testSimpleTypes(floatValues, TypeKindEnum.float);
    testSimpleTypes(floatValues, TypeKindEnum.double);

    var dateTimes = [DateTime.utc(2023), DateTime.utc(2022)];
    testSimpleTypes(dateTimes, TypeKindEnum.dateTime);

    var strings = ["jbb", "ohg", "monkey see monkey do", "☎☎♇♇"];
    testSimpleTypes(strings, TypeKindEnum.string);
  });

  final schema = StructureSchema(
    'SpeedBatcher',
    structureName: 'ST_SpeedBatcher',
  )
    ..addField(createPredefinedType(NodeId.numeric(0, 1), 'field1', []))
    ..addField(createPredefinedType(NodeId.numeric(0, 1), 'field2', []))
    ..addField(createPredefinedType(NodeId.numeric(0, 1), 'field3', []))
    ..addField(createPredefinedType(NodeId.numeric(0, 1), 'field4', []))
    ..addField(createPredefinedType(NodeId.numeric(0, 1), 'field5', []))
    ..addField(createPredefinedType(NodeId.numeric(0, 1), 'field6', []))
    ..addField(createPredefinedType(NodeId.numeric(0, 4), 'field7', []))
    ..addField(StructureSchema('field8', structureName: 'ST_FP')
      ..addField(createPredefinedType(NodeId.numeric(0, 1), 'subfield1', []))
      ..addField(createPredefinedType(NodeId.numeric(0, 1), 'subfield2', []))
      ..addField(createPredefinedType(NodeId.numeric(0, 1), 'subfield3',
          [2]))); // Array<DynamicValue> of size 2
  // Populate a struct type
  var myStructs = KnownStructures();
  myStructs.add(schema);

  test('Encode structs', () {
    var myMap = <String, dynamic>{
      "field1": false,
      "field2": true,
      "field3": false,
      "field4": true,
      "field5": false,
      "field6": true,
      "field7": 10,
      "field8": {
        "subfield1": false,
        "subfield2": true,
        "subfield3": false,
      }
    };
    LinkedHashMap hashMap = LinkedHashMap();
    hashMap.addAll(myMap);
    var myVal = DynamicValue(value: hashMap);
    testSimpleTypes(myVal, TypeKindEnum.extensionObject);
  });
}
