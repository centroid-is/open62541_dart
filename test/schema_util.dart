import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:open62541/src/generated/open62541_bindings.dart' as raw;
import 'package:open62541/src/library.dart';
import 'package:open62541/src/extensions.dart';
import 'package:open62541/src/node_id.dart';

Pointer<raw.UA_Variant> buildDef(List<Pointer<raw.UA_StructureField>> fields) {
  Pointer<raw.UA_Variant> retVariant = calloc<raw.UA_Variant>();
  Pointer<raw.UA_StructureDefinition> retValue = calloc<raw.UA_StructureDefinition>();
  retValue.ref.fields = calloc(fields.length);
  retValue.ref.fieldsSize = fields.length;

  for (var i = 0; i < fields.length; i++) {
    retValue.ref.fields[i] = fields[i].ref;
    calloc.free(fields[i]);
  }

  retVariant.ref.data = retValue.cast();
  retVariant.ref.type = Pointer.fromAddress(Open62541Singleton().lib.addresses.UA_TYPES.address +
      (raw.UA_TYPES_STRUCTUREDEFINITION * sizeOf<raw.UA_DataType>()));
  return retVariant;
}

Pointer<raw.UA_StructureField> buildField(NodeId typeId, String name, List<int> arrayDimensions, String description) {
  Pointer<raw.UA_StructureField> field = calloc();
  field.ref.dataType = typeId.toRaw(Open62541Singleton().lib);
  field.ref.name.set(name);
  field.ref.description.text.set(description);
  field.ref.description.locale.set("IS-is");
  field.ref.arrayDimensionsSize = arrayDimensions.length;
  field.ref.arrayDimensions = calloc(arrayDimensions.length);
  for (int i = 0; i < arrayDimensions.length; i++) {
    field.ref.arrayDimensions[i] = arrayDimensions[i];
  }
  return field;
}
