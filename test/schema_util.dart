import 'package:open62541/open62541.dart';

DynamicValue buildDef(NodeId typeId, List<DynamicValue> fields) {
  final ret = DynamicValue(typeId: typeId);

  for (var i = 0; i < fields.length; i++) {
    ret[i] = fields[i];
  }

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
