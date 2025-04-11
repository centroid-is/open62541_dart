import 'package:binarize/binarize.dart';
import 'schema.dart';
import '../nodeId.dart';
import 'payloads.dart';
import '../extensions.dart';

const _payloadTypes = [
  BooleanPayload(),
  UA_SBytePayload(),
  UA_BytePayload(),
  UA_Int16Payload(),
  UA_UInt16Payload(),
  UA_Int32Payload(),
  UA_UInt32Payload(),
  UA_Int64Payload(),
  UA_UInt64Payload(),
  UA_FloatPayload(),
  UA_DoublePayload(),
  StringPayload(),
];

StructureSchema createFromPayload(
    PayloadType payloadType, String fieldName, List<int> arrayDimensions,
    {String? structureName}) {
  for (var dimension in arrayDimensions) {
    payloadType = ArrayPayload(payloadType /*, dimension*/);
  }
  return StructureSchema(fieldName,
      structureName: structureName, elementType: payloadType);
}

PayloadType nodeIdToPayloadType(NodeId nodeIdType) {
  if (!nodeIdType.isNumeric()) {
    throw ArgumentError('NodeId is not numeric: $nodeIdType');
  }
  final typeKind = Namespace0Id.fromInt(nodeIdType.numeric).toTypeKind();
  for (var payloadType in _payloadTypes) {
    if (payloadType.typeKind == typeKind) {
      return payloadType as PayloadType;
    }
  }
  throw 'Unsupported field type: $nodeIdType';
}

StructureSchema createPredefinedType(
    NodeId nodeIdType, String fieldName, List<int> arrayDimensions) {
  final payloadType = nodeIdToPayloadType(nodeIdType);
  return createFromPayload(payloadType, fieldName, arrayDimensions);
}
