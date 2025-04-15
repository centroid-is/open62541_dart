import 'package:binarize/binarize.dart';
import 'package:open62541_bindings/src/dynamic_value.dart';
import 'schema.dart';
import '../nodeId.dart';
import 'payloads.dart';
import '../extensions.dart';

final _payloadTypes = {
  TypeKindEnum.boolean: BooleanPayload(),
  TypeKindEnum.sbyte: UA_SBytePayload(),
  TypeKindEnum.byte: UA_BytePayload(),
  TypeKindEnum.int16: UA_Int16Payload(),
  TypeKindEnum.uint16: UA_UInt16Payload(),
  TypeKindEnum.int32: UA_Int32Payload(),
  TypeKindEnum.uint32: UA_UInt32Payload(),
  TypeKindEnum.int64: UA_Int64Payload(),
  TypeKindEnum.uint64: UA_UInt64Payload(),
  TypeKindEnum.float: UA_FloatPayload(),
  TypeKindEnum.double: UA_DoublePayload(),
  TypeKindEnum.dateTime: UA_DateTimePayload(),
  TypeKindEnum.string: UA_StringPayload(),
  TypeKindEnum.outOfSpecContiguousString: ContiguousStringPayload(),
  TypeKindEnum.extensionObject: DynamicValue(),
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

StructureSchema createFromPayload(
    PayloadType payloadType, String fieldName, List<int> arrayDimensions,
    {String? structureName}) {
  for (var dimension in arrayDimensions) {
    // wrap the payload type in an array payload with StructureSchema which will make it a Array<DynamicValue>
    payloadType = ArrayPayload(StructureSchema(fieldName,
        elementType: payloadType, structureName: structureName));
    // payloadType = ArrayPayload(payloadType /*, dimension*/);
  }
  return StructureSchema(fieldName,
      structureName: structureName, elementType: payloadType);
}

PayloadType typeKindToPayloadType(TypeKindEnum typeKind) {
  final payloadType = _payloadTypes[typeKind];
  if (payloadType == null) {
    throw 'Unsupported field type: $typeKind';
  }
  return payloadType as PayloadType;
}

PayloadType nodeIdToPayloadType(NodeId nodeIdType) {
  if (!nodeIdType.isNumeric()) {
    throw ArgumentError('NodeId is not numeric: $nodeIdType');
  }
  return typeKindToPayloadType(
      Namespace0Id.fromInt(nodeIdType.numeric).toTypeKind());
}

StructureSchema createPredefinedType(
    NodeId nodeIdType, String fieldName, List<int> arrayDimensions) {
  final payloadType = nodeIdToPayloadType(nodeIdType);
  return createFromPayload(payloadType, fieldName, arrayDimensions);
}
