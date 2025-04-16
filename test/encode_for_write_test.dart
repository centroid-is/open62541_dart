import 'dart:collection';
import 'dart:convert';
import 'dart:ffi';
import 'package:open62541_bindings/src/dynamic_value.dart';
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
  void testSimpleTypes(dynamic value, NodeId kind) {
    final variant = Client.valueToVariant(value, lib);
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
    testSimpleTypes(true, NodeId.boolean);
    testSimpleTypes(false, NodeId.boolean);
  });

  test('Encode int variant', () {
    testSimpleTypes(10, NodeId.int16);
    testSimpleTypes(25, NodeId.uint16);
    testSimpleTypes(1337, NodeId.int32);
    testSimpleTypes(2556, NodeId.uint32);
    testSimpleTypes(10516, NodeId.int64);
    testSimpleTypes(11213, NodeId.uint64);

    // Test the min and max values of the integer types
    testSimpleTypes(-32768, NodeId.int16);
    testSimpleTypes(32767, NodeId.int16);

    testSimpleTypes(0, NodeId.uint16);
    testSimpleTypes(65535, NodeId.uint16);

    testSimpleTypes(-2147483648, NodeId.int32);
    testSimpleTypes(2147483647, NodeId.int32);

    testSimpleTypes(0, NodeId.uint32);
    testSimpleTypes(4294967295, NodeId.uint32);

    testSimpleTypes(0, NodeId.uint64);
    // There is not a native type in flutter to test this.
    // testSimpleTypes(18446744073709551615, NodeId.uint64);

    testSimpleTypes(-9223372036854775808, NodeId.int64);
    testSimpleTypes(9223372036854775807, NodeId.int64);
  });
  test('Encode float variant', () {
    testSimpleTypes(0.5, NodeId.float);
    testSimpleTypes(1.5, NodeId.double);
    testSimpleTypes(-0.5, NodeId.float);
    testSimpleTypes(-1.5, NodeId.double);
  });
  test('Encode string variant', () {
    testSimpleTypes("asdfasdf", NodeId.uastring);
  });
  test('Encode DateTime variant', () {
    testSimpleTypes(DateTime.utc(2025, 10, 5, 18, 30, 150), NodeId.datetime);
    testSimpleTypes(DateTime.utc(2024, 10, 5, 18, 30, 150), NodeId.datetime);
  });
  //TODO: Implement duration
  // test('Encode Duration variant', () {
  //   testSimpleTypes(Duration(milliseconds: 150), NodeId.);
  // });

  test('Encode arrays variant', () {
    var values = [false, false, true, true];
    testSimpleTypes(values, NodeId.boolean);

    var uintValues = [15, 25, 26, 27, 32, 99];
    var intValues = [15, 25, 26, 27, 32, 99, -11, -25, -99];
    testSimpleTypes(intValues, NodeId.int16);
    testSimpleTypes(intValues, NodeId.int32);
    testSimpleTypes(intValues, NodeId.int64);

    testSimpleTypes(uintValues, NodeId.uint16);
    testSimpleTypes(uintValues, NodeId.uint32);
    testSimpleTypes(uintValues, NodeId.uint64);

    var floatValues = [15.34, 25.12, 26.77, 27.82, 32.1, 99.0, -14.32];
    testSimpleTypes(floatValues, NodeId.float);
    testSimpleTypes(floatValues, NodeId.double);

    var dateTimes = [DateTime.utc(2023), DateTime.utc(2022)];
    testSimpleTypes(dateTimes, NodeId.datetime);

    var strings = ["jbb", "ohg", "monkey see monkey do", "☎☎♇♇"];
    testSimpleTypes(strings, NodeId.uastring);
  });

  final schema = StructureSchema(
    'SpeedBatcher',
    structureName: 'ST_SpeedBatcher',
  )
    ..addField(createPredefinedType(NodeId.fromNumeric(0, 1), 'field1', []))
    ..addField(createPredefinedType(NodeId.fromNumeric(0, 1), 'field2', []))
    ..addField(createPredefinedType(NodeId.fromNumeric(0, 1), 'field3', []))
    ..addField(createPredefinedType(NodeId.fromNumeric(0, 1), 'field4', []))
    ..addField(createPredefinedType(NodeId.fromNumeric(0, 1), 'field5', []))
    ..addField(createPredefinedType(NodeId.fromNumeric(0, 1), 'field6', []))
    ..addField(createPredefinedType(NodeId.fromNumeric(0, 4), 'field7', []))
    ..addField(StructureSchema('field8', structureName: 'ST_FP')
      ..addField(
          createPredefinedType(NodeId.fromNumeric(0, 1), 'subfield1', []))
      ..addField(
          createPredefinedType(NodeId.fromNumeric(0, 1), 'subfield2', []))
      ..addField(createPredefinedType(NodeId.fromNumeric(0, 1), 'subfield3',
          [2]))); // Array<DynamicValue> of size 2
  // Populate a struct type

  test('Encode structs', () {
    var myMap = <String, dynamic>{
      "field1": true,
      "field2": false,
      "field3": true,
      "field4": false,
      "field5": true,
      "field6": false,
      "field7": 42,
      "field8": {
        "subfield1": false,
        "subfield2": true,
        "subfield3": [false, true],
      }
    };
    var myVal = DynamicValue.fromMap(myMap);
    myVal.typeId = NodeId.fromString(4, "<StructuredDataType>:ST_SpeedBatcher");
    myVal["field1"].typeId = NodeId.boolean;
    myVal["field2"].typeId = NodeId.boolean;
    myVal["field3"].typeId = NodeId.boolean;
    myVal["field4"].typeId = NodeId.boolean;
    myVal["field5"].typeId = NodeId.boolean;
    myVal["field6"].typeId = NodeId.boolean;
    myVal["field7"].typeId = NodeId.int16;
    myVal["field8"].typeId = NodeId.fromString(4, "<StructuredDataType>:ST_FP");
    myVal["field8"]["subfield1"].typeId = NodeId.boolean;
    myVal["field8"]["subfield2"].typeId = NodeId.boolean;
    myVal["field8"]["subfield3"].typeId = NodeId.boolean;
    myVal["field8"]["subfield3"][0].typeId = NodeId.boolean;
    myVal["field8"]["subfield3"][1].typeId = NodeId.boolean;
    final variant = Client.valueToVariant(myVal, lib);

    ByteWriter writer = ByteWriter();
    myVal.set(writer, myVal, Endian.little);
    final bytes = writer.toBytes();
    ByteReader reader = ByteReader(bytes, endian: Endian.little);
    final decoded = myVal.get(reader, Endian.little);
    expect(decoded['field1'].asBool, true);
    expect(decoded['field2'].asBool, false);
    expect(decoded['field3'].asBool, true);
    expect(decoded['field4'].asBool, false);
    expect(decoded['field5'].asBool, true);
    expect(decoded['field6'].asBool, false);
    expect(decoded['field7'].asInt, 42);
    expect(decoded['field8']['subfield1'].asBool, false);
    expect(decoded['field8']['subfield2'].asBool, true);
    expect(decoded['field8']['subfield3'].asArray.length, 2);
    expect(decoded['field8']['subfield3'][0].asBool, false);
    expect(decoded['field8']['subfield3'][1].asBool, true);
    calloc.free(variant);
  });
}
