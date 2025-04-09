import 'package:binarize/binarize.dart';
import 'trivial.dart';
import '../extensions.dart';
import '../nodeId.dart';
import 'schema.dart';

StructureSchema createPredefinedType(NodeId nodeIdType, String fieldName) {
  if (!nodeIdType.isNumeric()) {
    throw 'Unsupported field type: $nodeIdType';
  }
  final fieldType = Namespace0Id.fromInt(nodeIdType.numeric);
  switch (fieldType) {
    case Namespace0Id.boolean:
      return StructureSchema(nodeIdType, fieldName, BooleanPayload());
    case Namespace0Id.sbyte:
      return StructureSchema(nodeIdType, fieldName, UA_SBytePayload());
    case Namespace0Id.byte:
      return StructureSchema(nodeIdType, fieldName, UA_BytePayload());
    case Namespace0Id.int16:
      return StructureSchema(nodeIdType, fieldName, UA_Int16Payload());
    case Namespace0Id.uint16:
      return StructureSchema(nodeIdType, fieldName, UA_UInt16Payload());
    case Namespace0Id.int32:
      return StructureSchema(nodeIdType, fieldName, UA_Int32Payload());
    case Namespace0Id.uint32:
      return StructureSchema(nodeIdType, fieldName, UA_UInt32Payload());
    case Namespace0Id.int64:
      return StructureSchema(nodeIdType, fieldName, UA_Int64Payload());
    case Namespace0Id.uint64:
      return StructureSchema(nodeIdType, fieldName, UA_UInt64Payload());
    // case Namespace0Id.float:
    //   return StructureSchema(nodeIdType, UA_FloatPayload());
    // case Namespace0Id.double:
    //   return StructureSchema(nodeIdType, UA_DoublePayload());
    // case Namespace0Id.string:
    //   return StructureSchema(nodeIdType, UA_StringPayload());
    // case Namespace0Id.dateTime:
    //   return StructureSchema(nodeIdType, UA_DateTimePayload());
    // case Namespace0Id.guid:
    //   break;
    // case Namespace0Id.byteString:
    //   break;
    // case Namespace0Id.xmlElement:
    //   break;
    // case Namespace0Id.nodeId:
    //   break;
    // case Namespace0Id.expandedNodeId:
    //   break;
    // case Namespace0Id.statusCode:
    //   break;
    // case Namespace0Id.qualifiedName:
    //   break;
    // case Namespace0Id.localizedText:
    //   break;
    // case Namespace0Id.structure:
    //   break;
    // case Namespace0Id.dataValue:
    //   break;
    // case Namespace0Id.basedataType:
    //   break;
    // case Namespace0Id.diagnosticInfo:
    //   break;
    default:
      throw 'Unsupported field type: $fieldType';
  }
}
