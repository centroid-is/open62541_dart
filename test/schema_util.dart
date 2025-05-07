import 'package:open62541/open62541.dart';

DynamicValue buildDef(NodeId typeId, List<DynamicValue> fields) {
  final ret = DynamicValue(typeId: typeId);
  // Pointer<raw.UA_Variant> retVariant = calloc<raw.UA_Variant>();
  // Pointer<raw.UA_StructureDefinition> retValue = calloc<raw.UA_StructureDefinition>();
  // retValue.ref.fields = calloc(fields.length);
  // retValue.ref.fieldsSize = fields.length;

  for (var i = 0; i < fields.length; i++) {
    ret[i] = fields[i];
  }

  // retVariant.ref.data = retValue.cast();
  // retVariant.ref.type = Pointer.fromAddress(Open62541Singleton().lib.addresses.UA_TYPES.address +
  //     (raw.UA_TYPES_STRUCTUREDEFINITION * sizeOf<raw.UA_DataType>()));
  return ret;
}

DynamicValue buildField(NodeId typeId, String name, List<int> arrayDimensions, String description) {
  final ret = DynamicValue(typeId: typeId);
  ret.name = name;
  ret.description = LocalizedText(description, "IS-is");
  if (arrayDimensions.isNotEmpty) {
    throw 'Unsupported array dimensions';
  }
  return ret;
}
