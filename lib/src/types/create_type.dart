import 'package:binarize/binarize.dart';
import 'package:open62541_bindings/src/dynamic_value.dart';
import 'schema.dart';
import '../nodeId.dart';
import 'payloads.dart';
import '../extensions.dart';

final _payloadTypes = {
  NodeId.boolean: BooleanPayload(),
  NodeId.sbyte: UA_SBytePayload(),
  NodeId.byte: UA_BytePayload(),
  NodeId.int16: UA_Int16Payload(),
  NodeId.uint16: UA_UInt16Payload(),
  NodeId.int32: UA_Int32Payload(),
  NodeId.uint32: UA_UInt32Payload(),
  NodeId.int64: UA_Int64Payload(),
  NodeId.uint64: UA_UInt64Payload(),
  NodeId.float: UA_FloatPayload(),
  NodeId.double: UA_DoublePayload(),
  NodeId.datetime: UA_DateTimePayload(),
  NodeId.uastring: UA_StringPayload(),
  // NodeId.: ContiguousStringPayload(),
  TypeKindEnum.extensionObject: DynamicValue(),
  TypeKindEnum.structure: DynamicValue(),
};

// Wraps the payload type in an array payload with the given dimensions
// It will set length to the dimension.
// If length is set, the length is not read from the binary buffer.
PayloadType wrapInArray(PayloadType payloadType, List<int> arrayDimensions) {
  for (var dimension in arrayDimensions) {
    payloadType = ArrayPayload(payloadType, dimension);
  }
  return payloadType;
}

StructureSchema createFromPayload(PayloadType payloadType, String fieldName,
    List<int> arrayDimensions, NodeId typeId,
    {String? structureName}) {
  for (var dimension in arrayDimensions) {
    // wrap the payload type in an array payload with StructureSchema which will make it a Array<DynamicValue>
    payloadType = ArrayPayload(StructureSchema(fieldName,
        elementType: payloadType,
        structureName: structureName,
        typeId: typeId));
    // payloadType = ArrayPayload(payloadType /*, dimension*/);
  }
  return StructureSchema(fieldName,
      structureName: structureName, elementType: payloadType, typeId: typeId);
}

PayloadType nodeIdToPayloadType(NodeId? nodeIdType) {
  if (nodeIdType == null || !nodeIdType.isNumeric()) {
    throw ArgumentError('NodeId is not numeric: $nodeIdType');
  }
  final payloadType = _payloadTypes[nodeIdType];
  if (payloadType == null) {
    throw 'Unsupported field type: $nodeIdType';
  }
  return payloadType as PayloadType;
}

StructureSchema createPredefinedType(
    NodeId typeId, String fieldName, List<int> arrayDimensions) {
  final payloadType = nodeIdToPayloadType(typeId);
  return createFromPayload(payloadType, fieldName, arrayDimensions, typeId);
}
