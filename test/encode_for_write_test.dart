import 'dart:ffi';

import 'package:open62541_bindings/src/dynamic_value.dart';
import 'package:open62541_bindings/src/generated/open62541_bindings.dart';
import 'package:open62541_bindings/src/library.dart';
import 'package:open62541_bindings/src/node_id.dart';
import 'package:test/test.dart';
import 'package:binarize/binarize.dart';
import 'package:ffi/ffi.dart';
import 'package:open62541_bindings/src/client.dart';

void main() {
  final lib = Open62541Singleton().lib;
  void testSimpleTypes(DynamicValue value) {
    final variant = Client.valueToVariant(value, lib);
    final decoded = Client.variantToValue(variant);
    expect(value.isArray, decoded.isArray);
    if (value.isArray) {
      expect(decoded.asArray.length, value.asArray.length);
      for (int i = 0; i < value.asArray.length; i++) {
        if (value[i].isDouble) {
          expect(value[i].asDouble, closeTo(decoded[i].asDouble, 1e-5));
        } else {
          expect(value[i].asDynamic, decoded[i].asDynamic);
        }
      }
    } else {
      if (value.isDouble) {
        expect(value.asDouble, closeTo(decoded.asDouble, 1e-5));
      } else {
        expect(value.asDynamic, decoded.asDynamic);
      }
    }
    calloc.free(variant);
  }

  test('Encode boolean variant', () {
    testSimpleTypes(DynamicValue(value: true, typeId: NodeId.boolean));
    testSimpleTypes(DynamicValue(value: false, typeId: NodeId.boolean));
  });

  test('Encode int variant', () {
    testSimpleTypes(DynamicValue(value: 10, typeId: NodeId.int16));
    testSimpleTypes(DynamicValue(value: 25, typeId: NodeId.uint16));
    testSimpleTypes(DynamicValue(value: 1337, typeId: NodeId.int32));
    testSimpleTypes(DynamicValue(value: 2556, typeId: NodeId.uint32));
    testSimpleTypes(DynamicValue(value: 10516, typeId: NodeId.int64));
    testSimpleTypes(DynamicValue(value: 11213, typeId: NodeId.uint64));

    // Test the min and max values of the integer types
    testSimpleTypes(DynamicValue(value: -32768, typeId: NodeId.int16));
    testSimpleTypes(DynamicValue(value: 32767, typeId: NodeId.int16));

    testSimpleTypes(DynamicValue(value: 0, typeId: NodeId.uint16));
    testSimpleTypes(DynamicValue(value: 65535, typeId: NodeId.uint16));
    testSimpleTypes(DynamicValue(value: -2147483648, typeId: NodeId.int32));
    testSimpleTypes(DynamicValue(value: 2147483647, typeId: NodeId.int32));
    testSimpleTypes(DynamicValue(value: 0, typeId: NodeId.uint32));
    testSimpleTypes(DynamicValue(value: 4294967295, typeId: NodeId.uint32));
    testSimpleTypes(DynamicValue(value: 0, typeId: NodeId.uint64));
    // There is not a native type in flutter to test this.
    // testSimpleTypes(18446744073709551615, NodeId.uint64);

    testSimpleTypes(
        DynamicValue(value: -9223372036854775808, typeId: NodeId.int64));
    testSimpleTypes(
        DynamicValue(value: 9223372036854775807, typeId: NodeId.int64));
  });
  test('Encode float variant', () {
    testSimpleTypes(DynamicValue(value: 0.5, typeId: NodeId.float));
    testSimpleTypes(DynamicValue(value: 1.5, typeId: NodeId.double));
    testSimpleTypes(DynamicValue(value: -0.5, typeId: NodeId.float));
    testSimpleTypes(DynamicValue(value: -1.5, typeId: NodeId.double));
  });
  test('Encode string variant', () {
    testSimpleTypes(DynamicValue(value: "asdfasdf", typeId: NodeId.uastring));
  });
  test('Encode DateTime variant', () {
    var firstArg = DateTime.utc(2025, 10, 5, 18, 30, 15, 150);
    var dfirstArg = DynamicValue(value: firstArg);
    testSimpleTypes(DynamicValue(value: firstArg, typeId: NodeId.datetime));
    testSimpleTypes(DynamicValue(
        value: DateTime.utc(2024, 10, 5, 18, 30, 15, 150),
        typeId: NodeId.datetime));
  });
  //TODO: Implement duration
  // test('Encode Duration variant', () {
  //   testSimpleTypes(Duration(milliseconds: 150), NodeId.);
  // });

  test('Encode arrays variant', () {
    var values = [false, false, true, true];
    testSimpleTypes(DynamicValue.fromList(values, typeId: NodeId.boolean));

    var uintValues = [15, 25, 26, 27, 32, 99];
    var intValues = [15, 25, 26, 27, 32, 99, -11, -25, -99];
    testSimpleTypes(DynamicValue.fromList(intValues, typeId: NodeId.int16));
    testSimpleTypes(DynamicValue.fromList(intValues, typeId: NodeId.int32));
    testSimpleTypes(DynamicValue.fromList(intValues, typeId: NodeId.int64));

    testSimpleTypes(DynamicValue.fromList(uintValues, typeId: NodeId.uint16));
    testSimpleTypes(DynamicValue.fromList(uintValues, typeId: NodeId.uint32));
    testSimpleTypes(DynamicValue.fromList(uintValues, typeId: NodeId.uint64));

    var floatValues = [15.34, 25.12, 26.77, 27.82, 32.1, 99.0, -14.32];
    testSimpleTypes(DynamicValue.fromList(floatValues, typeId: NodeId.float));
    testSimpleTypes(DynamicValue.fromList(floatValues, typeId: NodeId.double));

    var dateTimes = [DateTime.utc(2023), DateTime.utc(2022)];
    testSimpleTypes(DynamicValue.fromList(dateTimes, typeId: NodeId.datetime));

    var strings = ["jbb", "ohg", "monkey see monkey do", "☎☎♇♇"];
    testSimpleTypes(DynamicValue.fromList(strings, typeId: NodeId.uastring));
  });

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
