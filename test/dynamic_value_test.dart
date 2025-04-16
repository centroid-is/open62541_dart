import 'dart:ffi';

import 'package:binarize/binarize.dart';
import 'package:ffi/ffi.dart';
import 'package:open62541_bindings/src/dynamic_value.dart';
import 'package:open62541_bindings/src/extensions.dart';
import 'package:open62541_bindings/src/generated/open62541_bindings.dart'
    as raw;
import 'package:open62541_bindings/src/library.dart';
import 'package:test/test.dart';
import 'package:open62541_bindings/src/node_id.dart';

void main() {
  test('dynamic value', () {
    final dynamicValue = DynamicValue();
    expect(dynamicValue.type, DynamicType.nullValue);
  });

  test('add field', () {
    final dynamicValue = DynamicValue();
    dynamicValue['field1'] = DynamicValue();
    expect(dynamicValue.type, DynamicType.object);
  });

  test('add index', () {
    final dynamicValue = DynamicValue();
    dynamicValue[0] = DynamicValue();
    expect(dynamicValue.type, DynamicType.array);
  });

  test('add index out of bounds', () {
    final dynamicValue = DynamicValue();
    expect(() => dynamicValue[1] = DynamicValue(), throwsStateError);
  });

  test('set value', () {
    final dynamicValue = DynamicValue();
    dynamicValue.value = 42.2;
    expect(dynamicValue.type, DynamicType.double);
  });
  test('set sub values', () {
    var values = <String, dynamic>{
      "jbb": false,
      "ohg": true,
      "w": {
        "jbb": true,
        "w": {
          "ohg": false,
          "a": [
            {
              "jbb": false,
              "ohg": [
                {"final_boss": true},
                [
                  [1337]
                ]
              ]
            }
          ]
        }
      }
    };
    final d = DynamicValue.fromMap(values);
    expect(d["ohg"].asBool, true);
    expect(d["jbb"].asBool, false);
    expect(d["w"]["jbb"].asBool, true);
    expect(d["w"]["w"]["ohg"].asBool, false);
    expect(d["w"]["w"]["a"][0]["jbb"].asBool, false);
    expect(d["w"]["w"]["a"][0]["ohg"][0]["final_boss"].asBool, true);
    expect(d["w"]["w"]["a"][0]["ohg"][1][0][0].asInt, 1337);
    d["jbb"] = true;
    d["w"]["jbb"] = false;
    d["w"]["w"]["ohg"] = true;
    d["w"]["w"]["a"][0]["jbb"] = true;
    d["w"]["w"]["a"][0]["ohg"][0]["final_boss"] = false;
    d["w"]["w"]["a"][0]["ohg"][1][0][0] = 42;
    expect(d["jbb"].asBool, true);
    expect(d["w"]["jbb"].asBool, false);
    expect(d["w"]["w"]["ohg"].asBool, true);
    expect(d["w"]["w"]["a"][0]["jbb"].asBool, true);
    expect(d["w"]["w"]["a"][0]["ohg"][0]["final_boss"].asBool, false);
    expect(d["w"]["w"]["a"][0]["ohg"][1][0][0].asInt, 42);
  });
  test('typeId persistance trivial', () {
    DynamicValue k = DynamicValue(value: false, typeId: NodeId.boolean);
    expect(k.typeId, NodeId.boolean);
    k.value = true;
    expect(k.typeId, NodeId.boolean);
  });
  test('typeId persistance complex map', () {
    var values = <String, dynamic>{
      "jbb": false,
    };
    final d = DynamicValue.fromMap(values);
    d["jbb"].typeId = NodeId.boolean;
    expect(d["jbb"].typeId, NodeId.boolean);
    d["jbb"] = true;
    expect(d["jbb"].typeId, NodeId.boolean);
  });
  test('typeId persistance array', () {
    var values = [
      DynamicValue(value: true, typeId: NodeId.boolean),
      DynamicValue(value: false, typeId: NodeId.boolean),
    ];
    final d = DynamicValue.fromList(values);
    expect(d[0].typeId, NodeId.boolean);
    expect(d[1].typeId, NodeId.boolean);
    d[0] = false;
    d[1] = true;
    expect(d[0].typeId, NodeId.boolean);
    expect(d[1].typeId, NodeId.boolean);
  });

  test('Build dynamic Value from buffer', () {
    const data = [
      0x01, // field1
      0x00, // field2
      0x01, // field3
      0x00, // field4
      0x01, // field5
      0x00, // field6
      0x2a, // field7
      0x00, // field7
      0x00, // field8.subfield1
      0x01, // field8.subfield2
      0x02, // field8.subfield3.len
      0x00, // field8.subfield3.len
      0x00, // field8.subfield3.len
      0x00, // field8.subfield3.len
      0x00, // field8.subfield3[0]
      0x01, // field8.subfield3[1]
    ];

    DynamicValue empty = DynamicValue(typeId: NodeId.fromString(4, "sp"));
    empty["field1"] = DynamicValue(typeId: NodeId.boolean);
    empty["field2"] = DynamicValue(typeId: NodeId.boolean);
    empty["field3"] = DynamicValue(typeId: NodeId.boolean);
    empty["field4"] = DynamicValue(typeId: NodeId.boolean);
    empty["field5"] = DynamicValue(typeId: NodeId.boolean);
    empty["field6"] = DynamicValue(typeId: NodeId.boolean);
    empty["field7"] = DynamicValue(typeId: NodeId.int16);
    DynamicValue field8 = DynamicValue(typeId: NodeId.fromString(4, "fp"));
    field8["subfield1"] = DynamicValue(typeId: NodeId.boolean);
    field8["subfield2"] = DynamicValue(typeId: NodeId.boolean);
    DynamicValue subfield3 = DynamicValue(typeId: NodeId.boolean);
    subfield3[0] = DynamicValue(typeId: NodeId.boolean);
    subfield3[1] = DynamicValue(typeId: NodeId.boolean);
    field8["subfield3"] = subfield3;
    empty["field8"] = field8;

    final reader = ByteReader(Uint8List.fromList(data), endian: Endian.little);
    final result = empty.get(reader, Endian.little);
    assert(result['field1'].asBool == true);
    assert(result['field2'].asBool == false);
    assert(result['field3'].asBool == true);
    assert(result['field4'].asBool == false);
    assert(result['field5'].asBool == true);
    assert(result['field6'].asBool == false);
    assert(result['field7'].asInt == 42);
    assert(result['field8']['subfield1'].asBool == false);
    assert(result['field8']['subfield2'].asBool == true);
    assert(result['field8']['subfield3'].asArray.length == 2);
    assert(result['field8']['subfield3'][0].asBool == false);
    assert(result['field8']['subfield3'][1].asBool == true);

    final writer = ByteWriter(endian: Endian.little);
    empty.set(writer, result);
    assert(writer.length == data.length);
    var bytes = writer.toBytes();
    for (var i = 0; i < data.length; i++) {
      assert(bytes[i] == data[i]);
    }
  });

  Pointer<raw.UA_StructureDefinition> buildDef(
      List<Pointer<raw.UA_StructureField>> fields) {
    Pointer<raw.UA_StructureDefinition> retValue =
        calloc<raw.UA_StructureDefinition>();
    retValue.ref.fields = calloc(fields.length);
    retValue.ref.fieldsSize = fields.length;

    for (var i = 0; i < fields.length; i++) {
      retValue.ref.fields[i] = fields[i].ref;
      calloc.free(fields[i]);
    }

    return retValue;
  }

  Pointer<raw.UA_StructureField> buildField(NodeId typeId, String name,
      List<int> arrayDimensions, String description) {
    Pointer<raw.UA_StructureField> field = calloc();
    field.ref.dataType = typeId.toRaw(Open62541Singleton().lib);
    field.ref.name.set(name);
    field.ref.description.text.set(description);
    field.ref.description.locale.set("IS-is");
    field.ref.arrayDimensionsSize = arrayDimensions.length;
    field.ref.arrayDimensions = calloc(arrayDimensions.length);
    for (int i = 0; i < arrayDimensions.length; i++) {
      field.ref.arrayDimensions[i] = arrayDimensions[i];
    }
    return field;
  }

  test('Create DynamicValue schema', () {
    var fpNodeId = NodeId.fromString(4, "fp");
    List<Pointer<raw.UA_StructureField>> spFields = [
      buildField(NodeId.boolean, "field1", [], "ff"),
      buildField(NodeId.boolean, "field2", [], "ff"),
      buildField(NodeId.boolean, "field3", [], "ff"),
      buildField(NodeId.boolean, "field4", [], "ff"),
      buildField(NodeId.boolean, "field5", [], "ff"),
      buildField(NodeId.boolean, "field6", [], "ff"),
      buildField(NodeId.int16, "field7", [], "ff"),
      buildField(fpNodeId, "field8", [], "ff"),
    ];
    var sp = buildDef(spFields);

    List<Pointer<raw.UA_StructureField>> fpFields = [
      buildField(NodeId.boolean, "subfield1", [], "ff"),
      buildField(NodeId.boolean, "subfield2", [], "ff"),
      buildField(NodeId.boolean, "subfield3", [2], "ff"),
    ];

    var fp = buildDef(fpFields);

    var spNodeId = NodeId.fromString(4, "sp");
    var defs = {
      spNodeId: sp.ref,
      fpNodeId: fp.ref,
    };
    var schema =
        DynamicValue.fromDataTypeDefinition(NodeId.fromString(4, "sp"), defs);

    // Expect tree structure was made
    expect(schema.isObject, true);
    expect(schema.contains("field1"), true);
    expect(schema.contains("field2"), true);
    expect(schema.contains("field3"), true);
    expect(schema.contains("field4"), true);
    expect(schema.contains("field5"), true);
    expect(schema.contains("field6"), true);
    expect(schema.contains("field7"), true);
    expect(schema.contains("field8"), true);
    expect(schema["field8"].contains("subfield1"), true);
    expect(schema["field8"].contains("subfield2"), true);
    expect(schema["field8"].contains("subfield3"), true);
    expect(schema["field8"]["subfield3"].isArray, true);
    expect(schema["field8"]["subfield3"].asArray.length, 2);

    // Expect types propogated
    expect(schema["field1"].typeId, NodeId.boolean);
    expect(schema["field2"].typeId, NodeId.boolean);
    expect(schema["field3"].typeId, NodeId.boolean);
    expect(schema["field4"].typeId, NodeId.boolean);
    expect(schema["field5"].typeId, NodeId.boolean);
    expect(schema["field6"].typeId, NodeId.boolean);
    expect(schema["field7"].typeId, NodeId.int16);
    expect(schema["field8"].typeId, fpNodeId);
    expect(schema["field8"]["subfield1"].typeId, NodeId.boolean);
    expect(schema["field8"]["subfield2"].typeId, NodeId.boolean);
    expect(schema["field8"]["subfield3"].typeId, NodeId.boolean);
    expect(schema["field8"]["subfield3"][0].typeId, NodeId.boolean);
    expect(schema["field8"]["subfield3"][1].typeId, NodeId.boolean);
  });
}
