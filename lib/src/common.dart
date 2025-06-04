import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:binarize/binarize.dart' as binarize;
import 'package:ffi/ffi.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/types/create_type.dart';
import 'extensions.dart';
import 'generated/open62541_bindings.dart' as raw;

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

/// Loads the open62541 library.
///
/// By default, it attempts to load the library dynamically based on the platform:
/// - Linux: 'libopen62541.so'
/// - MacOS: 'libopen62541.dylib'
/// - Windows: 'libopen62541.dll'
///
/// If [staticLinking] is true:
/// - On Android: loads 'libopen62541.so' dynamically (static linking not supported)
/// - Other platforms: loads from the executable itself
/// This works with https://pub.dev/packages/open62541_libs
///
/// If [local] is true, loads from the package's lib directory.
/// If [path] is provided, loads from the specified path.
///
/// Returns:
///   A new [ffi.DynamicLibrary] instance.
ffi.DynamicLibrary loadOpen62541Library({bool staticLinking = false, bool local = false, Uri? path}) {
  if (staticLinking) {
    if (Platform.isAndroid) {
      return ffi.DynamicLibrary.open('libopen62541.so');
    } else {
      return ffi.DynamicLibrary.executable();
    }
  }
  var ending = 'so';
  if (Platform.isMacOS) {
    ending = 'dylib';
  } else if (Platform.isWindows) {
    ending = 'dll';
  }
  if (local) {
    var uri = Isolate.resolvePackageUriSync(Uri.parse('package:open62541/libopen62541.$ending'));
    return ffi.DynamicLibrary.open(uri!.path);
  }
  if (path != null) {
    return ffi.DynamicLibrary.open(path.path);
  }
  return ffi.DynamicLibrary.open('libopen62541.$ending');
}
