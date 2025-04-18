import 'package:binarize/binarize.dart';
import '../node_id.dart';
import 'payloads.dart';

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
};

PayloadType nodeIdToPayloadType(NodeId? nodeIdType) {
  if (nodeIdType == null || !nodeIdType.isNumeric()) {
    throw ArgumentError('NodeId is not numeric: $nodeIdType');
  }
  final retValue = _payloadTypes[nodeIdType];
  if (retValue == null) {
    throw 'Unsupported field type: $nodeIdType';
  }
  return retValue as PayloadType;
}
