import 'dart:ffi';

import 'package:open62541_bindings/src/dynamic_value.dart';
import 'package:open62541_bindings/src/generated/open62541_bindings.dart';
import 'package:open62541_bindings/src/generated/open62541_bindings.dart'
    as raw;
import 'package:open62541_bindings/src/library.dart';
import 'package:open62541_bindings/src/node_id.dart';
import 'package:open62541_bindings/src/extensions.dart';
import 'package:test/test.dart';
import 'package:binarize/binarize.dart';
import 'package:ffi/ffi.dart';
import 'package:open62541_bindings/src/client.dart';
import 'schema_util.dart';

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

  test('struct of strings variant to value and back', () {
    final DynamicValue val =
        DynamicValue(typeId: NodeId.fromString(4, "Omars string struct"));
    val["s1"] = DynamicValue(value: "some string", typeId: NodeId.uastring);
    val["s2"] = DynamicValue(value: "other string", typeId: NodeId.uastring);
    val["s3"] = DynamicValue(value: "third string", typeId: NodeId.uastring);
    final variant = Client.valueToVariant(val, lib);

    var spNodeId = NodeId.fromString(4, "Omars string struct");
    List<Pointer<raw.UA_StructureField>> spFields = [
      buildField(NodeId.uastring, "s1", [], "ff"),
      buildField(NodeId.uastring, "s2", [], "ff"),
      buildField(NodeId.uastring, "s3", [], "ff"),
    ];
    var sp = buildDef(spFields);

    var defs = {
      spNodeId: sp.ref,
    };
    final decoded = Client.variantToValue(variant, defs: defs);
    lib.UA_StructureDefinition_delete(sp);

    expect(val["s1"].asString, "some string");
    expect(val["s2"].asString, "other string");
    expect(val["s3"].asString, "third string");
    expect(val["s1"].asString, decoded["s1"].asString);
    expect(val["s2"].asString, decoded["s2"].asString);
    expect(val["s3"].asString, decoded["s3"].asString);
  });

  test('Array of structs variant to value and back', () {
    final DynamicValue val1 =
        DynamicValue(typeId: NodeId.fromString(4, "Omars string struct"));
    val1["s1"] = DynamicValue(value: "some string", typeId: NodeId.uastring);
    val1["s2"] = DynamicValue(value: "other string", typeId: NodeId.uastring);
    val1["s3"] = DynamicValue(value: "third string", typeId: NodeId.uastring);

    final DynamicValue val2 =
        DynamicValue(typeId: NodeId.fromString(4, "Omars string struct"));
    val2["s1"] = DynamicValue(value: "some string", typeId: NodeId.uastring);
    val2["s2"] = DynamicValue(value: "other string", typeId: NodeId.uastring);
    val2["s3"] = DynamicValue(value: "third string", typeId: NodeId.uastring);

    final DynamicValue val3 =
        DynamicValue(typeId: NodeId.fromString(4, "Omars string struct"));
    val3["s1"] = DynamicValue(value: "some string", typeId: NodeId.uastring);
    val3["s2"] = DynamicValue(value: "other string", typeId: NodeId.uastring);
    val3["s3"] = DynamicValue(value: "third string", typeId: NodeId.uastring);

    DynamicValue parent =
        DynamicValue.fromList([val1, val2, val3], typeId: val1.typeId);
    final variant = Client.valueToVariant(parent, lib);

    print(variant.ref.format());

    var spNodeId = NodeId.fromString(4, "Omars string struct");
    List<Pointer<raw.UA_StructureField>> spFields = [
      buildField(NodeId.uastring, "s1", [], "ff"),
      buildField(NodeId.uastring, "s2", [], "ff"),
      buildField(NodeId.uastring, "s3", [], "ff"),
    ];
    var sp = buildDef(spFields);

    var defs = {
      spNodeId: sp.ref,
    };
    // final decoded = Client.variantToValue(variant, defs: defs);

    // expect(val1["s1"].asString, "some string");
    // expect(val1["s2"].asString, "other string");
    // expect(val1["s3"].asString, "third string");
    // expect(val1["s1"].asString, decoded[0]["s1"].asString);
    // expect(val1["s2"].asString, decoded[0]["s2"].asString);
    // expect(val1["s3"].asString, decoded[0]["s3"].asString);
    // expect(val2["s1"].asString, decoded[1]["s1"].asString);
    // expect(val2["s2"].asString, decoded[1]["s2"].asString);
    // expect(val2["s3"].asString, decoded[1]["s3"].asString);
    // expect(val3["s1"].asString, decoded[2]["s1"].asString);
    // expect(val3["s2"].asString, decoded[2]["s2"].asString);
    // expect(val3["s3"].asString, decoded[2]["s3"].asString);
  });
  test('4x2 multi dimensional array', () {
    var data = [
      0x01,
      0x00,
      0x02,
      0x00,
      0x03,
      0x00,
      0x04,
      0x00,
      0x05,
      0x00,
      0x06,
      0x00,
      0x07,
      0x00,
      0x08,
      0x00
    ];
    Pointer<UA_Variant> variant = calloc();
    variant.ref.data = calloc<Uint8>(data.length).cast();
    variant.ref.data
        .cast<Uint8>()
        .asTypedList(data.length)
        .setRange(0, data.length, data);

    variant.ref.arrayLength = 0;
    variant.ref.arrayDimensionsSize = 2;
    variant.ref.arrayDimensions = calloc(2);
    variant.ref.arrayDimensions[0] = 4;
    variant.ref.arrayDimensions[1] = 2;
    variant.ref.type = Client.getType(UaTypes.int16, lib);
    final value = Client.variantToValue(variant);
    // print(value);
    expect(value.isArray, true);
    expect(value[0].isArray, true);
    expect(value[0].asArray.length, 2);
    expect(value[1].isArray, true);
    expect(value[1].asArray.length, 2);
    expect(value[2].isArray, true);
    expect(value[2].asArray.length, 2);
    expect(value[3].isArray, true);
    expect(value[3].asArray.length, 2);
    expect(value[0][0].asInt, 1);
    expect(value[0][1].asInt, 2);
    expect(value[1][0].asInt, 3);
    expect(value[1][1].asInt, 4);
    expect(value[2][0].asInt, 5);
    expect(value[2][1].asInt, 6);
    expect(value[3][0].asInt, 7);
    expect(value[3][1].asInt, 8);
    lib.UA_Variant_delete(variant);
  });
  test('4x4x2 boolean array', () {
    var data = [
      0x01,
      0x00,
      0x01,
      0x00,
      0x01,
      0x00,
      0x01,
      0x00,
      0x01,
      0x00,
      0x01,
      0x00,
      0x01,
      0x00,
      0x01,
      0x00,
      0x01,
      0x00,
      0x01,
      0x00,
      0x01,
      0x00,
      0x01,
      0x00,
      0x01,
      0x00,
      0x01,
      0x00,
      0x01,
      0x00,
      0x01,
      0x00
    ];
    Pointer<UA_Variant> variant = calloc();
    variant.ref.data = calloc<Uint8>(data.length).cast();
    variant.ref.data
        .cast<Uint8>()
        .asTypedList(data.length)
        .setRange(0, data.length, data);

    variant.ref.arrayLength = 0;
    variant.ref.arrayDimensionsSize = 3;
    variant.ref.arrayDimensions = calloc(3);
    variant.ref.arrayDimensions[0] = 4;
    variant.ref.arrayDimensions[1] = 4;
    variant.ref.arrayDimensions[2] = 2;
    variant.ref.type = Client.getType(UaTypes.boolean, lib);
    final value = Client.variantToValue(variant);
    // print(value);
    expect(value.isArray, true);
    expect(value[0].isArray, true);
    expect(value[0].asArray.length, 4);
    expect(value[1].isArray, true);
    expect(value[1].asArray.length, 4);
    expect(value[2].isArray, true);
    expect(value[2].asArray.length, 4);
    expect(value[3].isArray, true);
    expect(value[3].asArray.length, 4);
    expect(value[0][0].isArray, true);
    expect(value[0][1].isArray, true);
    expect(value[0][2].isArray, true);
    expect(value[0][3].isArray, true);
    expect(value[1][0].isArray, true);
    expect(value[1][1].isArray, true);
    expect(value[1][2].isArray, true);
    expect(value[1][3].isArray, true);
    expect(value[2][0].isArray, true);
    expect(value[2][1].isArray, true);
    expect(value[2][2].isArray, true);
    expect(value[2][3].isArray, true);
    expect(value[3][0].isArray, true);
    expect(value[3][1].isArray, true);
    expect(value[3][2].isArray, true);
    expect(value[3][3].isArray, true);
    expect(value[0][0][0].asBool, true);
    expect(value[0][0][1].asBool, false);
    expect(value[0][1][0].asBool, true);
    expect(value[0][1][1].asBool, false);
    expect(value[0][2][0].asBool, true);
    expect(value[0][2][1].asBool, false);
    expect(value[0][3][0].asBool, true);
    expect(value[0][3][1].asBool, false);
    expect(value[1][0][0].asBool, true);
    expect(value[1][0][1].asBool, false);
    expect(value[1][1][0].asBool, true);
    expect(value[1][1][1].asBool, false);
    expect(value[1][2][0].asBool, true);
    expect(value[1][2][1].asBool, false);
    expect(value[1][3][0].asBool, true);
    expect(value[1][3][1].asBool, false);
    expect(value[2][0][0].asBool, true);
    expect(value[2][0][1].asBool, false);
    expect(value[2][1][0].asBool, true);
    expect(value[2][1][1].asBool, false);
    expect(value[2][2][0].asBool, true);
    expect(value[2][2][1].asBool, false);
    expect(value[2][3][0].asBool, true);
    expect(value[2][3][1].asBool, false);
    expect(value[3][0][0].asBool, true);
    expect(value[3][0][1].asBool, false);
    expect(value[3][1][0].asBool, true);
    expect(value[3][1][1].asBool, false);
    expect(value[3][2][0].asBool, true);
    expect(value[3][2][1].asBool, false);
    expect(value[3][3][0].asBool, true);
    expect(value[3][3][1].asBool, false);
    lib.UA_Variant_delete(variant);
  });

  // TODO: Multi dimensional arrays inside structs
}
