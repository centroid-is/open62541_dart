import 'package:binarize/binarize.dart';
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
  TypeKindEnum.string: StringPayload(),
};

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

PayloadType nodeIdToPayloadType(NodeId nodeIdType) {
  if (!nodeIdType.isNumeric()) {
    throw ArgumentError('NodeId is not numeric: $nodeIdType');
  }
  final typeKind = Namespace0Id.fromInt(nodeIdType.numeric).toTypeKind();
  final payloadType = _payloadTypes[typeKind];
  if (payloadType == null) {
    throw 'Unsupported field type: $nodeIdType';
  }
  return payloadType as PayloadType;
}

StructureSchema createPredefinedType(
    NodeId nodeIdType, String fieldName, List<int> arrayDimensions) {
  final payloadType = nodeIdToPayloadType(nodeIdType);
  return createFromPayload(payloadType, fieldName, arrayDimensions);
}
