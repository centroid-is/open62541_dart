import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'extensions.dart';
import 'generated/open62541_bindings.dart' as raw;

import 'dynamic_value.dart';

import 'dart:ffi' as ffi;

import 'package:binarize/binarize.dart' as binarize;

String statusCodeToString(int statusCode, raw.open62541 lib) {
  return lib.UA_StatusCode_name(statusCode).cast<Utf8>().toDartString();
}

ffi.Pointer<raw.UA_DataType> getType(UaTypes uaType, raw.open62541 lib) {
  int type = uaType.value;
  if (type < 0 || type > raw.UA_TYPES_COUNT) {
    throw 'Type out of boundary $type';
  }
  return ffi.Pointer.fromAddress(lib.addresses.UA_TYPES.address + (type * ffi.sizeOf<raw.UA_DataType>()));
}

ffi.Pointer<raw.UA_Variant> valueToVariant(DynamicValue value, raw.open62541 lib) {
  ffi.Pointer<ffi.Uint8> pointer;

  binarize.ByteWriter wr = binarize.ByteWriter();
  value.set(wr, value, Endian.little, false, true);
  pointer = calloc<ffi.Uint8>(wr.length);
  pointer.asTypedList(wr.length).setRange(0, wr.length, wr.toBytes());

  Namespace0Id id;
  if (value.typeId!.isNumeric()) {
    id = Namespace0Id.fromInt(value.typeId!.numeric);
  } else {
    id = Namespace0Id.structure;
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
  ffi.Pointer<raw.UA_Variant> variant = calloc<raw.UA_Variant>();
  lib.UA_Variant_init(variant); // todo is this needed?
  variant.ref.data = pointer.cast();
  variant.ref.type = getType(id.toUaTypes(), lib);
  if (dimensions.isNotEmpty) {
    variant.ref.arrayLength = dimensions.fold(1, (a, b) => a * b);
  }
  if (dimensions.length > 1) {
    variant.ref.arrayDimensions = calloc<ffi.Uint32>(dimensions.length);
    variant.ref.arrayDimensions.asTypedList(dimensions.length).setRange(0, dimensions.length, dimensions);
    variant.ref.arrayDimensionsSize = dimensions.length;
  }

  return variant;
}
