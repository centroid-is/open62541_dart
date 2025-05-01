import 'dart:ffi';

import 'package:open62541/src/dynamic_value.dart';
import 'package:open62541/src/generated/open62541_bindings.dart';
import 'package:open62541/src/generated/open62541_bindings.dart' as raw;
import 'package:open62541/src/library.dart';
import 'package:open62541/src/node_id.dart';
import 'package:open62541/src/extensions.dart';
import 'package:test/test.dart';
import 'package:ffi/ffi.dart';
import 'package:open62541/src/client.dart';
import 'schema_util.dart';

void main() {
  final lib = Open62541Singleton().lib;
  void testSimpleTypes(DynamicValue value) {
    final variant = Client.valueToVariant(value, lib);
    final decoded = Client.variantToValue(variant.ref);
    expect(value.isArray, decoded.isArray);
    if (value.isArray) {
      expect(decoded.asArray.length, value.asArray.length);
      for (int i = 0; i < value.asArray.length; i++) {
        if (value[i].isDouble) {
          expect(value[i].asDouble, closeTo(decoded[i].asDouble, 1e-5));
        } else {
          expect(value[i].value, decoded[i].value);
        }
      }
    } else {
      if (value.isDouble) {
        expect(value.asDouble, closeTo(decoded.asDouble, 1e-5));
      } else {
        expect(value.value, decoded.value);
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

    testSimpleTypes(DynamicValue(value: -9223372036854775808, typeId: NodeId.int64));
    testSimpleTypes(DynamicValue(value: 9223372036854775807, typeId: NodeId.int64));
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
    testSimpleTypes(DynamicValue(value: firstArg, typeId: NodeId.datetime));
    testSimpleTypes(DynamicValue(value: DateTime.utc(2024, 10, 5, 18, 30, 15, 150), typeId: NodeId.datetime));
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
    final DynamicValue val = DynamicValue(typeId: NodeId.fromString(4, "Omars string struct"));
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

    var defs = {spNodeId: sp};
    final decoded = Client.variantToValue(variant.ref, defs: defs);
    lib.UA_Variant_delete(sp);

    expect(val["s1"].asString, "some string");
    expect(val["s2"].asString, "other string");
    expect(val["s3"].asString, "third string");
    expect(val["s1"].asString, decoded["s1"].asString);
    expect(val["s2"].asString, decoded["s2"].asString);
    expect(val["s3"].asString, decoded["s3"].asString);
  });

  test('Array of structs variant to value and back', () {
    final DynamicValue val1 = DynamicValue(typeId: NodeId.fromString(4, "Omars string struct"));
    val1["s1"] = DynamicValue(value: "some string", typeId: NodeId.uastring);
    val1["s2"] = DynamicValue(value: "other string", typeId: NodeId.uastring);
    val1["s3"] = DynamicValue(value: "third string", typeId: NodeId.uastring);

    final DynamicValue val2 = DynamicValue(typeId: NodeId.fromString(4, "Omars string struct"));
    val2["s1"] = DynamicValue(value: "some string", typeId: NodeId.uastring);
    val2["s2"] = DynamicValue(value: "other string", typeId: NodeId.uastring);
    val2["s3"] = DynamicValue(value: "third string", typeId: NodeId.uastring);

    final DynamicValue val3 = DynamicValue(typeId: NodeId.fromString(4, "Omars string struct"));
    val3["s1"] = DynamicValue(value: "some string", typeId: NodeId.uastring);
    val3["s2"] = DynamicValue(value: "other string", typeId: NodeId.uastring);
    val3["s3"] = DynamicValue(value: "third string", typeId: NodeId.uastring);

    DynamicValue parent = DynamicValue.fromList([val1, val2, val3], typeId: val1.typeId);
    final variant = Client.valueToVariant(parent, lib);

    var spNodeId = NodeId.fromString(4, "Omars string struct");
    List<Pointer<raw.UA_StructureField>> spFields = [
      buildField(NodeId.uastring, "s1", [], "ff"),
      buildField(NodeId.uastring, "s2", [], "ff"),
      buildField(NodeId.uastring, "s3", [], "ff"),
    ];
    var sp = buildDef(spFields);

    var defs = {spNodeId: sp};
    final decoded = Client.variantToValue(variant.ref, defs: defs);

    expect(val1["s1"].asString, "some string");
    expect(val1["s2"].asString, "other string");
    expect(val1["s3"].asString, "third string");
    expect(val1["s1"].asString, decoded[0]["s1"].asString);
    expect(val1["s2"].asString, decoded[0]["s2"].asString);
    expect(val1["s3"].asString, decoded[0]["s3"].asString);
    expect(val2["s1"].asString, decoded[1]["s1"].asString);
    expect(val2["s2"].asString, decoded[1]["s2"].asString);
    expect(val2["s3"].asString, decoded[1]["s3"].asString);
    expect(val3["s1"].asString, decoded[2]["s1"].asString);
    expect(val3["s2"].asString, decoded[2]["s2"].asString);
    expect(val3["s3"].asString, decoded[2]["s3"].asString);
  });
  test('4x2 multi dimensional array', () {
    var data = [0x01, 0x00, 0x02, 0x00, 0x03, 0x00, 0x04, 0x00, 0x05, 0x00, 0x06, 0x00, 0x07, 0x00, 0x08, 0x00];
    Pointer<UA_Variant> variant = calloc();
    variant.ref.data = calloc<Uint8>(data.length).cast();
    variant.ref.data.cast<Uint8>().asTypedList(data.length).setRange(0, data.length, data);

    variant.ref.arrayLength = 8;
    variant.ref.arrayDimensionsSize = 2;
    variant.ref.arrayDimensions = calloc(2);
    variant.ref.arrayDimensions[0] = 4;
    variant.ref.arrayDimensions[1] = 2;
    variant.ref.type = Client.getType(UaTypes.int16, lib);
    final value = Client.variantToValue(variant.ref);

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

    final variantEncoded = Client.valueToVariant(value, lib);
    expect(variantEncoded.ref.arrayLength, 8);
    final variantData = variantEncoded.ref.data.cast<Uint8>().asTypedList(data.length);
    expect(variantData, data);
    lib.UA_Variant_delete(variant);
    lib.UA_Variant_delete(variantEncoded);
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
      0x00,
    ];
    Pointer<UA_Variant> variant = calloc();
    variant.ref.data = calloc<Uint8>(data.length).cast();
    variant.ref.data.cast<Uint8>().asTypedList(data.length).setRange(0, data.length, data);

    variant.ref.arrayLength = 32;
    variant.ref.arrayDimensionsSize = 3;
    variant.ref.arrayDimensions = calloc(3);
    variant.ref.arrayDimensions[0] = 4;
    variant.ref.arrayDimensions[1] = 4;
    variant.ref.arrayDimensions[2] = 2;
    variant.ref.type = Client.getType(UaTypes.boolean, lib);
    void expectArrayDyn(DynamicValue value) {
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
    }

    final dynValueFromBuffer = Client.variantToValue(variant.ref);
    expectArrayDyn(dynValueFromBuffer);

    final variantEncoded = Client.valueToVariant(dynValueFromBuffer, lib);
    expect(variantEncoded.ref.arrayLength, 32);
    final variantData = variantEncoded.ref.data.cast<Uint8>().asTypedList(data.length);
    expect(variantData, data);

    final decoded = Client.variantToValue(variantEncoded.ref);
    expectArrayDyn(decoded);
    lib.UA_Variant_delete(variant);
    lib.UA_Variant_delete(variantEncoded);
  });

  // BIG TODO generated test, verify its correctness
  test('2x3x4 array of string structs', () {
    var data = [
      // [0][0][0] - Position A
      2, 0, 0, 0, 97, 65, 0, // aA
      2, 0, 0, 0, 98, 65, 0, // bA
      2, 0, 0, 0, 99, 65, 0, // cA
      // [0][0][1] - Position B
      2, 0, 0, 0, 97, 66, 0, // aB
      2, 0, 0, 0, 98, 66, 0, // bB
      2, 0, 0, 0, 99, 66, 0, // cB
      // [0][0][2] - Position C
      2, 0, 0, 0, 97, 67, 0, // aC
      2, 0, 0, 0, 98, 67, 0, // bC
      2, 0, 0, 0, 99, 67, 0, // cC
      // [0][0][3] - Position D
      2, 0, 0, 0, 97, 68, 0, // aD
      2, 0, 0, 0, 98, 68, 0, // bD
      2, 0, 0, 0, 99, 68, 0, // cD
      // [0][1][0] - Position E
      2, 0, 0, 0, 97, 69, 0, // aE
      2, 0, 0, 0, 98, 69, 0, // bE
      2, 0, 0, 0, 99, 69, 0, // cE
      // [0][1][1] - Position F
      2, 0, 0, 0, 97, 70, 0, // aF
      2, 0, 0, 0, 98, 70, 0, // bF
      2, 0, 0, 0, 99, 70, 0, // cF
      // [0][1][2] - Position G
      2, 0, 0, 0, 97, 71, 0, // aG
      2, 0, 0, 0, 98, 71, 0, // bG
      2, 0, 0, 0, 99, 71, 0, // cG
      // [0][1][3] - Position H
      2, 0, 0, 0, 97, 72, 0, // aH
      2, 0, 0, 0, 98, 72, 0, // bH
      2, 0, 0, 0, 99, 72, 0, // cH
      // [0][2][0] - Position I
      2, 0, 0, 0, 97, 73, 0, // aI
      2, 0, 0, 0, 98, 73, 0, // bI
      2, 0, 0, 0, 99, 73, 0, // cI
      // [0][2][1] - Position J
      2, 0, 0, 0, 97, 74, 0, // aJ
      2, 0, 0, 0, 98, 74, 0, // bJ
      2, 0, 0, 0, 99, 74, 0, // cJ
      // [0][2][2] - Position K
      2, 0, 0, 0, 97, 75, 0, // aK
      2, 0, 0, 0, 98, 75, 0, // bK
      2, 0, 0, 0, 99, 75, 0, // cK
      // [0][2][3] - Position L
      2, 0, 0, 0, 97, 76, 0, // aL
      2, 0, 0, 0, 98, 76, 0, // bL
      2, 0, 0, 0, 99, 76, 0, // cL
      // [1][0][0] - Position M
      2, 0, 0, 0, 97, 77, 0, // aM
      2, 0, 0, 0, 98, 77, 0, // bM
      2, 0, 0, 0, 99, 77, 0, // cM
      // [1][0][1] - Position N
      2, 0, 0, 0, 97, 78, 0, // aN
      2, 0, 0, 0, 98, 78, 0, // bN
      2, 0, 0, 0, 99, 78, 0, // cN
      // [1][0][2] - Position O
      2, 0, 0, 0, 97, 79, 0, // aO
      2, 0, 0, 0, 98, 79, 0, // bO
      2, 0, 0, 0, 99, 79, 0, // cO
      // [1][0][3] - Position P
      2, 0, 0, 0, 97, 80, 0, // aP
      2, 0, 0, 0, 98, 80, 0, // bP
      2, 0, 0, 0, 99, 80, 0, // cP
      // [1][1][0] - Position Q
      2, 0, 0, 0, 97, 81, 0, // aQ
      2, 0, 0, 0, 98, 81, 0, // bQ
      2, 0, 0, 0, 99, 81, 0, // cQ
      // [1][1][1] - Position R
      2, 0, 0, 0, 97, 82, 0, // aR
      2, 0, 0, 0, 98, 82, 0, // bR
      2, 0, 0, 0, 99, 82, 0, // cR
      // [1][1][2] - Position S
      2, 0, 0, 0, 97, 83, 0, // aS
      2, 0, 0, 0, 98, 83, 0, // bS
      2, 0, 0, 0, 99, 83, 0, // cS
      // [1][1][3] - Position T
      2, 0, 0, 0, 97, 84, 0, // aT
      2, 0, 0, 0, 98, 84, 0, // bT
      2, 0, 0, 0, 99, 84, 0, // cT
      // [1][2][0] - Position U
      2, 0, 0, 0, 97, 85, 0, // aU
      2, 0, 0, 0, 98, 85, 0, // bU
      2, 0, 0, 0, 99, 85, 0, // cU
      // [1][2][1] - Position V
      2, 0, 0, 0, 97, 86, 0, // aV
      2, 0, 0, 0, 98, 86, 0, // bV
      2, 0, 0, 0, 99, 86, 0, // cV
      // [1][2][2] - Position W
      2, 0, 0, 0, 97, 87, 0, // aW
      2, 0, 0, 0, 98, 87, 0, // bW
      2, 0, 0, 0, 99, 87, 0, // cW
      // [1][2][3] - Position X
      2, 0, 0, 0, 97, 88, 0, // aX
      2, 0, 0, 0, 98, 88, 0, // bX
      2, 0, 0, 0, 99, 88, 0, // cX
    ];

    Pointer<UA_Variant> variant = calloc();
    variant.ref.data = calloc<Uint8>(data.length).cast();
    variant.ref.data.cast<Uint8>().asTypedList(data.length).setRange(0, data.length, data);

    variant.ref.arrayLength = 24;
    variant.ref.arrayDimensionsSize = 3;
    variant.ref.arrayDimensions = calloc(3);
    variant.ref.arrayDimensions[0] = 2;
    variant.ref.arrayDimensions[1] = 3;
    variant.ref.arrayDimensions[2] = 4;
    variant.ref.type = Client.getType(UaTypes.int16, lib);

    var spNodeId = NodeId.fromString(4, "Omars string struct");
    List<Pointer<raw.UA_StructureField>> spFields = [
      buildField(NodeId.uastring, "s1", [], "ff"),
      buildField(NodeId.uastring, "s2", [], "ff"),
      buildField(NodeId.uastring, "s3", [], "ff"),
    ];
    var sp = buildDef(spFields);
    var defs = {spNodeId: sp};

    final value = Client.variantToValue(variant.ref, defs: defs);

    expect(value.isArray, true);
    expect(value.asArray.length, 2);
    expect(value[0].asArray.length, 3);
    expect(value[0][0].asArray.length, 4);

    // Test first struct
    expect(value[0][0][0]["s1"].asString, "aA");
    expect(value[0][0][0]["s2"].asString, "bA");
    expect(value[0][0][0]["s3"].asString, "cA");

    // Test last struct
    expect(value[1][2][3]["s1"].asString, "aX");
    expect(value[1][2][3]["s2"].asString, "bX");
    expect(value[1][2][3]["s3"].asString, "cX");

    // Test middle position
    expect(value[1][0][0]["s1"].asString, "aM");
    expect(value[1][0][0]["s2"].asString, "bM");
    expect(value[1][0][0]["s3"].asString, "cM");

    lib.UA_Variant_delete(sp);
    lib.UA_Variant_delete(variant);
  }, skip: "Todo: make this test from real data");

  test('Array of nested struct', () {
    var data = <List<int>>[
      <int>[
        0x01,
        0x00,
        0x00,
        0x0e,
        0x42,
        0x00,
        0x01,
        0x00,
        0x9a,
        0x99,
        0x0d,
        0x42,
        0x00,
        0x13,
        0x00,
        0x00,
        0x00,
        0x4e,
        0x6f,
        0x74,
        0x68,
        0x69,
        0x6e,
        0x67,
        0x20,
        0x68,
        0x65,
        0x72,
        0x65,
        0x20,
        0x74,
        0x6f,
        0x20,
        0x73,
        0x65,
        0x65,
        0x00,
        0x01,
        0x00,
        0x01,
        0x00,
        0x01,
        0x00,
        0x01,
        0x0c,
        0x00,
        0x00,
        0x00,
        0x52,
        0x75,
        0x6e,
        0x6e,
        0x69,
        0x6e,
        0x67,
        0x20,
        0x62,
        0x61,
        0x62,
        0x79,
        0x11,
        0x00,
        0x00,
        0x00,
        0x4e,
        0x6f,
        0x74,
        0x68,
        0x69,
        0x6e,
        0x67,
        0x20,
        0x74,
        0x6f,
        0x20,
        0x72,
        0x65,
        0x70,
        0x6f,
        0x72,
        0x74,
        0x00,
        0xe0,
        0xf6,
        0x45,
        0xe1,
        0x7a,
        0x7c,
        0x41,
        0xdc,
        0x05,
        0x00,
        0x00,
      ],
      <int>[
        0x00,
        0x85,
        0xeb,
        0x97,
        0x41,
        0x00,
        0x01,
        0x00,
        0xae,
        0x47,
        0xcd,
        0x41,
        0x01,
        0x11,
        0x00,
        0x00,
        0x00,
        0x67,
        0x65,
        0x74,
        0x20,
        0x6d,
        0x65,
        0x20,
        0x73,
        0x6f,
        0x6d,
        0x65,
        0x20,
        0x77,
        0x6f,
        0x72,
        0x64,
        0x73,
        0x00,
        0x01,
        0x00,
        0x01,
        0x00,
        0x01,
        0x00,
        0x01,
        0x19,
        0x00,
        0x00,
        0x00,
        0x69,
        0x74,
        0x20,
        0x69,
        0x73,
        0x20,
        0x68,
        0x61,
        0x72,
        0x64,
        0x20,
        0x6d,
        0x61,
        0x6b,
        0x69,
        0x6e,
        0x67,
        0x20,
        0x75,
        0x70,
        0x20,
        0x64,
        0x61,
        0x74,
        0x61,
        0x15,
        0x00,
        0x00,
        0x00,
        0x68,
        0x6f,
        0x77,
        0x20,
        0x69,
        0x73,
        0x20,
        0x79,
        0x6f,
        0x75,
        0x72,
        0x20,
        0x64,
        0x61,
        0x79,
        0x20,
        0x67,
        0x6f,
        0x69,
        0x6e,
        0x67,
        0xe1,
        0xfa,
        0xc7,
        0x42,
        0x14,
        0xae,
        0xc8,
        0x42,
        0xc4,
        0x09,
        0x00,
        0x00,
      ],
      <int>[
        0x01,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x01,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x12,
        0x00,
        0x00,
        0x00,
        0x4c,
        0x61,
        0x73,
        0x74,
        0x20,
        0x6f,
        0x6e,
        0x65,
        0x20,
        0x69,
        0x20,
        0x70,
        0x72,
        0x6f,
        0x6d,
        0x69,
        0x73,
        0x65,
        0x00,
        0x01,
        0x00,
        0x00,
        0x01,
        0x00,
        0x01,
        0x00,
        0x18,
        0x00,
        0x00,
        0x00,
        0x68,
        0x65,
        0x72,
        0x65,
        0x20,
        0x69,
        0x73,
        0x20,
        0x6d,
        0x65,
        0x20,
        0x61,
        0x6e,
        0x64,
        0x20,
        0x69,
        0x20,
        0x61,
        0x6d,
        0x20,
        0x68,
        0x65,
        0x72,
        0x65,
        0x1a,
        0x00,
        0x00,
        0x00,
        0x74,
        0x68,
        0x69,
        0x73,
        0x20,
        0x73,
        0x74,
        0x72,
        0x69,
        0x6e,
        0x67,
        0x20,
        0x6e,
        0x65,
        0x65,
        0x64,
        0x73,
        0x20,
        0x61,
        0x20,
        0x76,
        0x61,
        0x6c,
        0x75,
        0x65,
        0x20,
        0xcd,
        0xa0,
        0x8c,
        0x45,
        0x66,
        0x36,
        0x11,
        0x45,
        0x40,
        0x06,
        0x00,
        0x00,
      ],
    ];

    var atvId = NodeId.fromString(4, "FB_ATV");

    Pointer<UA_Variant> variant = calloc();
    Pointer<raw.UA_ExtensionObject> ext = calloc(3);
    // Set encoding
    ext[0].encodingAsInt = raw.UA_ExtensionObjectEncoding.UA_EXTENSIONOBJECT_ENCODED_BYTESTRING.value;
    ext[1].encodingAsInt = raw.UA_ExtensionObjectEncoding.UA_EXTENSIONOBJECT_ENCODED_BYTESTRING.value;
    ext[2].encodingAsInt = raw.UA_ExtensionObjectEncoding.UA_EXTENSIONOBJECT_ENCODED_BYTESTRING.value;

    // Set types
    ext[0].content.encoded.typeId = atvId.toRaw(lib);
    ext[1].content.encoded.typeId = atvId.toRaw(lib);
    ext[2].content.encoded.typeId = atvId.toRaw(lib);

    // Set the data
    ext[0].content.encoded.body.length = data[0].length;
    ext[1].content.encoded.body.length = data[1].length;
    ext[2].content.encoded.body.length = data[2].length;

    // Allocate buffers
    ext[0].content.encoded.body.data = calloc(data[0].length);
    ext[1].content.encoded.body.data = calloc(data[1].length);
    ext[2].content.encoded.body.data = calloc(data[2].length);

    // Copy the data into buffers
    ext[0].content.encoded.body.data.asTypedList(data[0].length).setRange(0, data[0].length, data[0]);
    ext[1].content.encoded.body.data.asTypedList(data[1].length).setRange(0, data[1].length, data[1]);
    ext[2].content.encoded.body.data.asTypedList(data[2].length).setRange(0, data[2].length, data[2]);

    variant.ref.data = ext.cast();
    variant.ref.arrayLength = 3;
    variant.ref.arrayDimensionsSize = 0;
    variant.ref.type = Client.getType(UaTypes.extensionObject, lib);

    var hmiNodeId = NodeId.fromString(4, "FB_ATV.HMI");
    List<Pointer<raw.UA_StructureField>> hmiFields = [
      buildField(NodeId.boolean, "p_cmd_JogFwd", [], "ff"),
      buildField(NodeId.boolean, "p_cmd_JogBwd", [], "ff"),
      buildField(NodeId.boolean, "p_cmd_ResetRunHours", [], "ff"),
      buildField(NodeId.boolean, "p_cmd_ManualStopOnRelease", [], "ff"),
      buildField(NodeId.boolean, "p_stat_JogFwd", [], "ff"),
      buildField(NodeId.boolean, "p_stat_JogBwd", [], "ff"),
      buildField(NodeId.boolean, "p_stat_xResetRunHours", [], "ff"),
      buildField(NodeId.boolean, "p_stat_StopOnRelease", [], "ff"),
      buildField(NodeId.uastring, "p_stat_State", [], "ff"),
      buildField(NodeId.uastring, "p_stat_LastFault", [], "ff"),
      buildField(NodeId.float, "p_stat_rFrequency", [], "ff"),
      buildField(NodeId.float, "p_stat_rCurrent", [], "ff"),
      buildField(NodeId.uint32, "p_stat_duRunMinutes", [], "ff"),
    ];

    List<Pointer<raw.UA_StructureField>> atvFields = [
      buildField(NodeId.boolean, "i_xRun", [], "ff"),
      buildField(NodeId.float, "i_rFreq", [], "ff"),
      buildField(NodeId.boolean, "q_xRunning", [], "ff"),
      buildField(NodeId.boolean, "q_xFwd", [], "ff"),
      buildField(NodeId.boolean, "q_xBwd", [], "ff"),
      buildField(NodeId.float, "q_rFreq", [], "ff"),
      buildField(NodeId.boolean, "q_xError", [], "ff"),
      buildField(NodeId.uastring, "q_sError", [], "ff"),
      buildField(NodeId.fromString(4, "FB_ATV.HMI"), "HMI", [], "ff"),
    ];
    var atv = buildDef(atvFields);
    var hmi = buildDef(hmiFields);

    var defs = {atvId: atv, hmiNodeId: hmi};

    final value = Client.variantToValue(variant.ref, defs: defs);

    void expectArrayDyn(DynamicValue value) {
      // Validate array length
      expect(value.isArray, true);
      expect(value.asArray.length, 3);
      expect(value[0].isObject, true);
      expect(value[0]["i_xRun"].value, true);
      expect(value[0]["i_rFreq"].value, 35.5);
      expect(value[0]["q_xRunning"].value, false);
      expect(value[0]["q_xFwd"].value, true);
      expect(value[0]["q_xBwd"].value, false);
      expect(value[0]["q_rFreq"].value, closeTo(35.4, 1e-5));
      expect(value[0]["q_xError"].value, false);
      expect(value[0]["q_sError"].value, "Nothing here to see");
      expect(value[0]["HMI"].isObject, true);

      expect(value[0]["HMI"]["p_cmd_JogFwd"].value, false);
      expect(value[0]["HMI"]["p_cmd_JogBwd"].value, true);
      expect(value[0]["HMI"]["p_cmd_ResetRunHours"].value, false);
      expect(value[0]["HMI"]["p_cmd_ManualStopOnRelease"].value, true);
      expect(value[0]["HMI"]["p_stat_JogFwd"].value, false);
      expect(value[0]["HMI"]["p_stat_JogBwd"].value, true);
      expect(value[0]["HMI"]["p_stat_xResetRunHours"].value, false);
      expect(value[0]["HMI"]["p_stat_StopOnRelease"].value, true);
      expect(value[0]["HMI"]["p_stat_State"].value, "Running baby");
      expect(value[0]["HMI"]["p_stat_LastFault"].value, "Nothing to report");
      expect(value[0]["HMI"]["p_stat_rFrequency"].value, 7900);
      expect(value[0]["HMI"]["p_stat_rCurrent"].value, closeTo(15.78, 1e-5));
      expect(value[0]["HMI"]["p_stat_duRunMinutes"].value, 1500);

      expect(value[1].isObject, true);
      expect(value[1]["i_xRun"].value, false);
      expect(value[1]["i_rFreq"].value, closeTo(18.99, 1e-5));
      expect(value[1]["q_xRunning"].value, false);
      expect(value[1]["q_xFwd"].value, true);
      expect(value[1]["q_xBwd"].value, false);
      expect(value[1]["q_rFreq"].value, closeTo(25.66, 1e-5));
      expect(value[1]["q_xError"].value, true);
      expect(value[1]["q_sError"].value, "get me some words");
      expect(value[1]["HMI"].isObject, true);

      expect(value[1]["HMI"]["p_cmd_JogFwd"].value, false);
      expect(value[1]["HMI"]["p_cmd_JogBwd"].value, true);
      expect(value[1]["HMI"]["p_cmd_ResetRunHours"].value, false);
      expect(value[1]["HMI"]["p_cmd_ManualStopOnRelease"].value, true);
      expect(value[1]["HMI"]["p_stat_JogFwd"].value, false);
      expect(value[1]["HMI"]["p_stat_JogBwd"].value, true);
      expect(value[1]["HMI"]["p_stat_xResetRunHours"].value, false);
      expect(value[1]["HMI"]["p_stat_StopOnRelease"].value, true);
      expect(value[1]["HMI"]["p_stat_State"].value, "it is hard making up data");
      expect(value[1]["HMI"]["p_stat_LastFault"].value, "how is your day going");
      expect(value[1]["HMI"]["p_stat_rFrequency"].value, closeTo(99.99, 1e-5));
      expect(value[1]["HMI"]["p_stat_rCurrent"].value, closeTo(100.34, 1e-5));
      expect(value[1]["HMI"]["p_stat_duRunMinutes"].value, 2500);

      expect(value[2].isObject, true);
      expect(value[2]["i_xRun"].value, true);
      expect(value[2]["i_rFreq"].value, 0);
      expect(value[2]["q_xRunning"].value, false);
      expect(value[2]["q_xFwd"].value, true);
      expect(value[2]["q_xBwd"].value, false);
      expect(value[2]["q_rFreq"].value, closeTo(0, 1e-5));
      expect(value[2]["q_xError"].value, false);
      expect(value[2]["q_sError"].value, "Last one i promise");
      expect(value[2]["HMI"].isObject, true);

      expect(value[2]["HMI"]["p_cmd_JogFwd"].value, false);
      expect(value[2]["HMI"]["p_cmd_JogBwd"].value, true);
      expect(value[2]["HMI"]["p_cmd_ResetRunHours"].value, false);
      expect(value[2]["HMI"]["p_cmd_ManualStopOnRelease"].value, false);
      expect(value[2]["HMI"]["p_stat_JogFwd"].value, true);
      expect(value[2]["HMI"]["p_stat_JogBwd"].value, false);
      expect(value[2]["HMI"]["p_stat_xResetRunHours"].value, true);
      expect(value[2]["HMI"]["p_stat_StopOnRelease"].value, false);
      expect(value[2]["HMI"]["p_stat_State"].value, "here is me and i am here");
      expect(value[2]["HMI"]["p_stat_LastFault"].value, "this string needs a value ");
      expect(value[2]["HMI"]["p_stat_rFrequency"].value, closeTo(4500.1, 1e-4));
      expect(value[2]["HMI"]["p_stat_rCurrent"].value, closeTo(2323.4, 1e-4));
      expect(value[2]["HMI"]["p_stat_duRunMinutes"].value, 1600);
    }

    expectArrayDyn(value);

    final variantEncoded = Client.valueToVariant(value, lib);
    expect(variantEncoded.ref.arrayLength, 3);
    final dynValueAgain = Client.variantToValue(variantEncoded.ref, defs: defs);
    expectArrayDyn(dynValueAgain);

    lib.UA_Variant_delete(hmi);
    lib.UA_Variant_delete(atv);
    // I presume this erases the data correctly
    lib.UA_Variant_delete(variant);
    lib.UA_Variant_delete(variantEncoded);
  });

  // TODO: Multi dimensional arrays inside structs
}
