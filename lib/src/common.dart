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

ffi.Pointer<raw.UA_DataType> getType(UaTypes uaType) {
  int type = uaType.value;
  if (type < 0 || type > raw.UA_TYPES_COUNT) {
    throw 'Type out of boundary $type';
  }
  final baseAddress = ffi.Native.addressOf<raw.UA_DataType>(raw.UA_TYPES);
  return ffi.Pointer.fromAddress(baseAddress.address + (type * ffi.sizeOf<raw.UA_DataType>()));
}

/// Sentinel `data` pointer that open62541 uses to distinguish an array of
/// length 0 (empty array) from a null variant (`data == NULL`) or a scalar
/// (`data` above the sentinel). Mirrors `UA_EMPTY_ARRAY_SENTINEL` which is a C
/// macro (`(void*)0x01`) and therefore not emitted into the generated bindings.
final ffi.Pointer<ffi.Void> _uaEmptyArraySentinel = ffi.Pointer.fromAddress(0x01);

ffi.Pointer<raw.UA_Variant> valueToVariant(DynamicValue value) {
  final isEmptyArray = value.isArray && value.asArray.isEmpty;

  binarize.ByteWriter wr = binarize.ByteWriter();
  OpcUaDynamicValueSerializer.serialize(value, wr, value, Endian.little, false, true);

  Namespace0Id? id;
  if (value.typeId != null && value.typeId!.isNumeric()) {
    id = Namespace0Id.fromInt(value.typeId!.numeric);
  }

  List<int> getDimensions(DynamicValue value) {
    if (!value.isArray) {
      return [];
    }
    if (value.asArray.isEmpty) {
      // A zero-length array is legal in OPC UA. Represent it as a single
      // dimension of length 0 (arrayLength 0 + the empty-array sentinel below).
      return [0];
    }
    var dims = [value.asArray.length];
    if (value[0].isArray) {
      dims.addAll(getDimensions(value[0]));
    }
    return dims;
  }

  final dimensions = getDimensions(value);
  ffi.Pointer<raw.UA_Variant> variant = raw.UA_Variant_new();

  if (isEmptyArray) {
    // Empty array: no payload. Point at the sentinel so open62541 reads this
    // back as an array of length 0 rather than a null variant or a scalar.
    variant.ref.data = _uaEmptyArraySentinel;
  } else {
    final pointer = ua_calloc<ffi.Uint8>(wr.length);
    pointer.asTypedList(wr.length).setRange(0, wr.length, wr.toBytes());
    variant.ref.data = pointer.cast();
  }

  // Determine the element type from the innermost element: for a multi-dimensional
  // array the first element is itself an array, so peel arrays until a leaf is
  // reached. A struct leaf means the whole (possibly nested) array is encoded as
  // an array of extension objects.
  DynamicValue? innermostLeaf(DynamicValue v) {
    var cur = v;
    while (cur.isArray) {
      if (cur.asArray.isEmpty) return null;
      cur = cur.asArray.first;
    }
    return cur;
  }

  final leaf = innermostLeaf(value);
  final hasObjectElement = value.isArray && leaf != null && leaf.isObject;
  if (value.isObject || hasObjectElement) {
    variant.ref.type = getType(UaTypes.extensionObject);
  } else if (id != null) {
    variant.ref.type = getType(id.toUaTypes()); //TODO: This is not really the correct.
  } else if (isEmptyArray) {
    // The element type cannot be recovered from an untyped empty array: there
    // is no element to inspect and no numeric typeId to map to a UA type.
    throw ArgumentError('Cannot encode an empty array without a known element type; set DynamicValue.typeId.');
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

  // Empty array: arrayLength 0 with data pointing at the empty-array sentinel
  // (as opposed to a real pointer, which would be a scalar). Read it back as an
  // array of length 0 rather than dereferencing the sentinel.
  if (data.arrayLength == 0 && data.data.address == _uaEmptyArraySentinel.address) {
    return DynamicValue(value: <DynamicValue>[], typeId: typeId);
  }

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
    // The declared DataType has no known payload and no schema — e.g. a vendor
    // alias of a simple type (TwinCAT exposes STRING at a custom NodeId like
    // ns=3;i=3013). Fall back to the variant's actual wire type, which open62541
    // knows how to decode.
    final wireTypeId = data.type.ref.typeId.toNodeId();
    if (wireTypeId != typeId && nodeIdToPayloadType(wireTypeId) != null) {
      return DynamicValue(typeId: wireTypeId);
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
  OpcUaDynamicValueSerializer.deserialize(retValue, reader, Endian.little, false, true);
  retValue.extObjEncodingId = extObjEncodingId;

  return retValue;
}
