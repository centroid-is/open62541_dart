import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:binarize/binarize.dart';
import 'package:open62541_bindings/src/types/schema.dart';
import 'package:open62541_bindings/src/nodeId.dart';
import 'package:open62541_bindings/src/types/trivial.dart';
import 'package:open62541_bindings/src/types/array.dart';

void main() {
  test('Parse extension object byte string', () {
    final schema = StructureSchema(
      NodeId.string(0, 'ST_SpeedBatcher'),
      'SpeedBatcher',
    )
      ..addField(
          StructureSchema(NodeId.numeric(0, 1), 'field1', BooleanPayload()))
      ..addField(
          StructureSchema(NodeId.numeric(0, 1), 'field2', BooleanPayload()))
      ..addField(
          StructureSchema(NodeId.numeric(0, 1), 'field3', BooleanPayload()))
      ..addField(
          StructureSchema(NodeId.numeric(0, 1), 'field4', BooleanPayload()))
      ..addField(
          StructureSchema(NodeId.numeric(0, 1), 'field5', BooleanPayload()))
      ..addField(
          StructureSchema(NodeId.numeric(0, 1), 'field6', BooleanPayload()))
      ..addField(
          StructureSchema(NodeId.numeric(0, 4), 'field7', UA_Int16Payload()))
      ..addField(StructureSchema(NodeId.string(0, 'ST_FP'), 'field8')
        ..addField(StructureSchema(
            NodeId.numeric(0, 1), 'subfield1', BooleanPayload()))
        ..addField(StructureSchema(
            NodeId.numeric(0, 1), 'subfield2', BooleanPayload()))
        ..addField(StructureSchema(
            NodeId.numeric(0, 1),
            'subfield3',
            ArrayPayload(StructureSchema(
                NodeId.numeric(0, 1), 'subfield3', BooleanPayload())))));
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
    final reader = ByteReader(Uint8List.fromList(data), endian: Endian.little);
    final result = schema.get(reader);
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
    schema.set(writer, result);
    assert(writer.length == data.length);
    var bytes = writer.toBytes();
    for (var i = 0; i < data.length; i++) {
      assert(bytes[i] == data[i]);
    }
  });
}
