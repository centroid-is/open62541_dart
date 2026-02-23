import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:binarize/binarize.dart' as binarize;
import 'package:ffi/ffi.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/types/create_type.dart';
import 'extensions.dart';
import 'third_party/open62541.g.dart' as raw;
import 'ua_allocation.dart';

String statusCodeToString(int statusCode) {
  return raw.UA_StatusCode_name(statusCode).cast<Utf8>().toDartString();
}

/// Allocates and populates a UA_LocalizedText from a Dart [LocalizedText].
/// Caller must free the returned pointer with UA_LocalizedText_delete.
ffi.Pointer<raw.UA_LocalizedText> localizedTextToRaw(LocalizedText lt) {
  final ptr = raw.UA_LocalizedText_new();
  // Only set locale if non-empty. open62541's stringOrder treats
  // {length=0, data=NULL} and {length=0, data=non-NULL} as NOT equal,
  // so we must leave empty locales as {0, NULL} to match node defaults.
  if (lt.locale.isNotEmpty) {
    ptr.ref.locale.set(lt.locale);
  }
  ptr.ref.text.set(lt.value);
  return ptr;
}

ffi.Pointer<raw.UA_DataType> getType(UaTypes uaType) {
  int type = uaType.value;
  if (type < 0 || type > raw.UA_TYPES_COUNT) {
    throw 'Type out of boundary $type';
  }
  final baseAddress = ffi.Native.addressOf<raw.UA_DataType>(raw.UA_TYPES);
  return ffi.Pointer.fromAddress(baseAddress.address + (type * ffi.sizeOf<raw.UA_DataType>()));
}

ffi.Pointer<raw.UA_Variant> valueToVariant(DynamicValue value) {
  binarize.ByteWriter wr = binarize.ByteWriter();
  value.set(wr, value, Endian.little, false, true);
  final pointer = ua_calloc<ffi.Uint8>(wr.length);
  pointer.asTypedList(wr.length).setRange(0, wr.length, wr.toBytes());

  Namespace0Id? id;
  if (value.typeId!.isNumeric()) {
    id = Namespace0Id.fromInt(value.typeId!.numeric);
  }

  List<int> getDimensions(DynamicValue value) {
    if (!value.isArray) {
      return [];
    }
    if (value.asArray.isEmpty) {
      // I would like this to be an error case
      throw ArgumentError('Empty array');
    }
    var dims = [value.asArray.length];
    if (value[0].isArray) {
      dims.addAll(getDimensions(value[0]));
    }
    return dims;
  }

  final dimensions = getDimensions(value);
  ffi.Pointer<raw.UA_Variant> variant = raw.UA_Variant_new();
  variant.ref.data = pointer.cast();
  // Check if the leaf elements are objects (structs) — recurse through nested arrays
  DynamicValue leaf = value;
  while (leaf.isArray) {
    leaf = leaf.asArray.first;
  }
  if (leaf.isObject) {
    variant.ref.type = getType(UaTypes.extensionObject);
  } else if (id != null) {
    variant.ref.type = getType(id.toUaTypes()); //TODO: This is not really the correct.
  } else {
    throw 'Unable to determine type for $value';
  }
  if (dimensions.isNotEmpty) {
    variant.ref.arrayLength = dimensions.fold(1, (a, b) => a * b);
  }
  if (dimensions.length > 1) {
    variant.ref.arrayDimensions = ua_calloc<ffi.Uint32>(dimensions.length);
    variant.ref.arrayDimensions.asTypedList(dimensions.length).setRange(0, dimensions.length, dimensions);
    variant.ref.arrayDimensionsSize = dimensions.length;
  }

  return variant;
}

DynamicValue variantToValue(raw.UA_Variant data, {Schema? defs, NodeId? dataTypeId}) {
  // Check if the variant contains no data
  if (data.data == ffi.nullptr) {
    return DynamicValue();
  }

  var typeId = dataTypeId ?? data.type.ref.typeId.toNodeId();
  NodeId? extObjEncodingId;
  if (data.type.ref.typeKind == raw.UA_DataTypeKind.UA_DATATYPEKIND_EXTENSIONOBJECT) {
    final ext = data.data.cast<raw.UA_ExtensionObject>();
    extObjEncodingId = ext.ref.content.encoded.typeId.toNodeId();
  }

  final dimensions = data.dimensions;
  final dimensionsMultiplied = dimensions.fold(1, (a, b) => a * b);
  final bufferLength = dimensionsMultiplied * data.type.ref.memSize;
  DynamicValue retValue;

  // Read structure from opc-ua server
  DynamicValue dynamicValueSchema(NodeId typeId) {
    if (nodeIdToPayloadType(typeId) != null) {
      return DynamicValue(typeId: typeId);
    }
    if (defs != null && defs.containsKey(typeId)) {
      return DynamicValue.from(defs[typeId]!);
    }
    throw 'Unsupported nodeId type: $typeId';
  }

  DynamicValue createNestedArray(NodeId typeId, List<int> dims) {
    if (dims.isEmpty) {
      return dynamicValueSchema(typeId);
    }

    DynamicValue list = DynamicValue(typeId: typeId);
    if (dims.length == 1) {
      // Base case: create array of the final dimension
      for (int i = 0; i < dims[0]; i++) {
        list[i] = dynamicValueSchema(typeId);
      }
    } else {
      for (int i = 0; i < dims[0]; i++) {
        list[i] = createNestedArray(typeId, dims.sublist(1));
      }
    }
    return list;
  }

  retValue = createNestedArray(typeId, dimensions.toList());
  final reader = binarize.ByteReader(data.data.cast<ffi.Uint8>().asTypedList(bufferLength));
  retValue.get(reader, Endian.little, false, true);
  retValue.extObjEncodingId = extObjEncodingId;

  return retValue;
}
