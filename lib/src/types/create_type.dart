import 'package:binarize/binarize.dart';
import 'schema.dart';
import '../nodeId.dart';
import 'payloads.dart';

final _payloadTypes = [
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
];

StructureSchema createPredefinedType(
    NodeId nodeIdType, String fieldName, List<int> arrayDimensions) {
  if (!nodeIdType.isNumeric()) {
    throw 'Unsupported field type: $nodeIdType';
  }
  for (var payloadType in _payloadTypes) {
    if (payloadType.nodeIdType == nodeIdType) {
      var result = payloadType as PayloadType;
      for (var dimension in arrayDimensions) {
        result = ArrayPayload(result /*, dimension*/);
      }
      return StructureSchema(nodeIdType, fieldName, result);
    }
  }
  throw 'Unsupported field type: $nodeIdType, \navailable types:\n ${_payloadTypes.map((e) => e.nodeIdType).join('\n')}';
}
