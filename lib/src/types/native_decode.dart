import 'dart:collection' show LinkedHashMap;
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:binarize/binarize.dart' as binarize;
import 'package:ffi/ffi.dart';

import '../common.dart';
import '../dynamic_value.dart';
import '../extensions.dart';
import '../node_id.dart';
import '../third_party/open62541.g.dart' as raw;
import '../ua_allocation.dart';
import 'create_type.dart';
import 'errors.dart';
import 'opcua_serializer.dart';

/// Decoding of values from the in-memory layout open62541 gives a type it
/// knows.
///
/// When a value's DataType is one of the `UA_TYPES` (every NS0 DataType, e.g.
/// `ServerStatusDataType`, `BuildInfo`, `Argument`, `Range`) or a custom type
/// registered with open62541, the library decodes the ExtensionObject it
/// received into the native struct: the variant's `type` is that `UA_DataType`
/// (typeKind STRUCTURE, OPTSTRUCT or UNION) and `data` points at struct memory,
/// never at an encoded body. [decodeNativeVariant] walks that memory by the
/// type's `UA_DataTypeMember` table and produces the same [DynamicValue] shape
/// the ExtensionObject path produces for a custom type: an object of named
/// fields, nested objects, arrays, enums as Int32 with `enumFields`.
///
/// Layout rules, from `include/open62541/types.h` (`UA_DataTypeMember`) and
/// the member loops of `src/ua_types.c` (`copyStructure`, `clearStructure`,
/// `copyUnion`) and `src/ua_types_encoding_binary.c` (`encodeBinaryStruct`):
///
/// * `padding` is the number of bytes to skip BEFORE the member, counted from
///   the end of the previous member. For an array member it precedes the
///   `size_t` length; there is no padding between the length and the pointer
///   that follows it. For a union member it is the offset from the start of
///   the union type, so it includes the `UInt32` switch field.
/// * A scalar member occupies `memberType->memSize` bytes.
/// * An array member is a `size_t` length followed by a pointer to the
///   elements, each `memberType->memSize` bytes apart. A length of 0 comes
///   with a NULL pointer or `UA_EMPTY_ARRAY_SENTINEL` (0x1), never read.
/// * An optional scalar member is one pointer (NULL when absent); an optional
///   array member is the `size_t` length and the pointer (NULL when absent).
/// * A union is a `UInt32` switch field selecting `members[switch - 1]`, 0 for
///   no member.
/// * An enum is an `Int32`; the enum type's members list the possible values,
///   each `memberType` cast to an integer and `memberName` the value's name.

/// `UA_DataTypeKind`s whose variant payload is native struct memory.
bool isNativeStructKind(raw.UA_DataTypeKind kind) {
  return kind == raw.UA_DataTypeKind.UA_DATATYPEKIND_STRUCTURE ||
      kind == raw.UA_DataTypeKind.UA_DATATYPEKIND_OPTSTRUCT ||
      kind == raw.UA_DataTypeKind.UA_DATATYPEKIND_UNION;
}

/// `UA_EMPTY_ARRAY_SENTINEL`, a C macro (`(void*)0x01`) not emitted into the
/// bindings: the `data` pointer of an array of length 0.
final ffi.Pointer<ffi.Void> _emptyArraySentinel = ffi.Pointer.fromAddress(0x01);

/// Decodes a variant whose `type` is a structure open62541 knows (see
/// [isNativeStructKind]): a scalar, an array of `arrayLength` structs of
/// `memSize` bytes each, or a multi-dimensional array (row-major, nested
/// lists). [defs] decodes an encoded ExtensionObject member whose type a
/// schema is known for.
DynamicValue decodeNativeVariant(raw.UA_Variant data, {Schema? defs}) {
  final type = data.type;
  return _decodeElements(
    data,
    type.ref.memSize,
    (element) => decodeNative(element, type, defs: defs),
    listTypeId: type.ref.typeId.toNodeId(),
  );
}

/// Decodes a variant of ExtensionObjects whose first one is an encoded body
/// of a type the bundled open62541 knows (its encoding id is the
/// `binaryEncodingId` of a `UA_TYPES` entry), or null when it is not: the
/// caller's own ExtensionObject path applies then. Each body is decoded with
/// `UA_decodeBinary` into a native struct and walked, see
/// [decodeEncodedKnown]; a value the Dart server published as an encoded
/// ExtensionObject reads back the way a client receives it over the wire.
DynamicValue? decodeEncodedExtensionObjects(raw.UA_Variant data, {Schema? defs}) {
  final first = data.data.cast<raw.UA_ExtensionObject>().ref;
  if (first.encoding != raw.UA_ExtensionObjectEncoding.UA_EXTENSIONOBJECT_ENCODED_BYTESTRING) return null;
  final type = findNs0DataTypeByEncodingId(first.content.encoded.typeId.toNodeId());
  if (type == null) return null;
  return _decodeElements(
    data,
    ffi.sizeOf<raw.UA_ExtensionObject>(),
    (element) => _decodeExtensionObject(element.cast<raw.UA_ExtensionObject>().ref, defs),
    listTypeId: type.ref.typeId.toNodeId(),
  );
}

/// Decodes a variant of ExtensionObjects with whatever is at hand and never
/// fails on an unknown type: each body is decoded by the schema [defs] holds
/// under its encoding id, or as the bundled type it is the encoding of, and
/// otherwise kept as its bytes (`typeId` Structure, `extObjEncodingId` the
/// wire id) so nothing is lost. For a client whose address space describes
/// the ExtensionObject's type nowhere (a relayed value under a foreign
/// encoding id, a type without a DataType node).
DynamicValue decodeExtensionObjectsOpaque(raw.UA_Variant data, {Schema? defs}) {
  return _decodeElements(
    data,
    ffi.sizeOf<raw.UA_ExtensionObject>(),
    (element) => _decodeExtensionObject(element.cast<raw.UA_ExtensionObject>().ref, defs),
    listTypeId: NodeId.structure,
  );
}

/// The variant's payload as a scalar, a list or nested lists (row-major over
/// `arrayDimensions`), each element [elementSize] bytes apart.
DynamicValue _decodeElements(
  raw.UA_Variant data,
  int elementSize,
  DynamicValue Function(ffi.Pointer<ffi.Void> element) decodeElement, {
  required NodeId listTypeId,
}) {
  final dimensions = data.dimensions;
  if (dimensions.isEmpty) {
    return decodeElement(data.data);
  }
  var index = 0;
  DynamicValue nested(List<int> dims) {
    final list = DynamicValue(typeId: listTypeId);
    list.value = <DynamicValue>[];
    for (var i = 0; i < dims[0]; i++) {
      if (dims.length == 1) {
        list[i] = decodeElement(ffi.Pointer.fromAddress(data.data.address + index * elementSize));
        index++;
      } else {
        list[i] = nested(dims.sublist(1));
      }
    }
    return list;
  }

  return nested(dimensions.toList());
}

/// Decodes the value of [type] at [ptr], any `UA_DataTypeKind`.
///
/// Built-in scalars map to the same Dart values the ExtensionObject path
/// produces (numbers, `bool`, `String`, `DateTime`); a Guid is its canonical
/// text, a NodeId a [NodeId], a LocalizedText a [LocalizedText], a ByteString
/// a `Uint8List` copy. An ExpandedNodeId, QualifiedName, DataValue and
/// DiagnosticInfo are objects of their fields; a nested Variant is decoded
/// through [variantToValue]; a nested ExtensionObject is decoded when it is
/// already decoded or [defs] has a schema for it, else its encoded body is
/// kept as bytes with `extObjEncodingId` set. A union is an object holding
/// the selected member only (empty for switch field 0). Nothing here keeps a
/// reference into native memory: every value is copied out.
DynamicValue decodeNative(ffi.Pointer<ffi.Void> ptr, ffi.Pointer<raw.UA_DataType> type, {Schema? defs}) {
  final t = type.ref;
  final typeId = t.typeId.toNodeId();
  switch (t.typeKind) {
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_BOOLEAN:
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_SBYTE:
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_BYTE:
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_INT16:
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_UINT16:
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_INT32:
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_UINT32:
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_INT64:
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_UINT64:
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_FLOAT:
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_DOUBLE:
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_DATETIME:
      // Same decoders as the binary path: the in-memory layout of these kinds
      // is their wire layout (open62541 marks them `overlayable`). A subtype
      // such as UtcTime or Duration has its own typeId but a built-in kind.
      final payloadTypeId = _builtinTypeId(t.typeKind);
      final reader = binarize.ByteReader(ptr.cast<ffi.Uint8>().asTypedList(t.memSize));
      return DynamicValue(value: nodeIdToPayloadType(payloadTypeId)!.get(reader, Endian.little), typeId: typeId);
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_STRING:
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_XMLELEMENT:
      return DynamicValue(value: ptr.cast<raw.UA_String>().ref.value, typeId: typeId);
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_BYTESTRING:
      return DynamicValue(value: Uint8List.fromList(ptr.cast<raw.UA_String>().ref.asTypedList()), typeId: typeId);
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_GUID:
      return DynamicValue(value: ptr.cast<raw.UA_Guid>().ref.text, typeId: typeId);
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_NODEID:
      return DynamicValue(value: ptr.cast<raw.UA_NodeId>().ref.toNodeId(), typeId: typeId);
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_EXPANDEDNODEID:
      final expanded = ptr.cast<raw.UA_ExpandedNodeId>().ref;
      final value = DynamicValue(typeId: typeId);
      value['NodeId'] = DynamicValue(value: expanded.nodeId.toNodeId(), typeId: NodeId.nodeId);
      value['NamespaceUri'] = DynamicValue(value: expanded.namespaceUri.value, typeId: NodeId.uastring);
      value['ServerIndex'] = DynamicValue(value: expanded.serverIndex, typeId: NodeId.uint32);
      return value;
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_STATUSCODE:
      return DynamicValue(value: ptr.cast<ffi.Uint32>().value, typeId: typeId);
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_QUALIFIEDNAME:
      final qualified = ptr.cast<raw.UA_QualifiedName>().ref;
      final value = DynamicValue(typeId: typeId);
      value['NamespaceIndex'] = DynamicValue(value: qualified.namespaceIndex, typeId: NodeId.uint16);
      value['Name'] = DynamicValue(value: qualified.name.value, typeId: NodeId.uastring);
      return value;
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_LOCALIZEDTEXT:
      return DynamicValue(value: ptr.cast<raw.UA_LocalizedText>().ref.localizedText, typeId: typeId);
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_EXTENSIONOBJECT:
      return _decodeExtensionObject(ptr.cast<raw.UA_ExtensionObject>().ref, defs);
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_DATAVALUE:
      return _decodeDataValue(ptr.cast<raw.UA_DataValue>().ref, typeId, defs);
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_VARIANT:
      return variantToValue(ptr.cast<raw.UA_Variant>().ref, defs: defs);
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_DIAGNOSTICINFO:
      return _decodeDiagnosticInfo(ptr.cast<raw.UA_DiagnosticInfo>().ref, typeId);
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_ENUM:
      // Int32 on the wire and in memory. The typeId is Int32 the way
      // OpcUaDynamicValueSerializer.fromDataTypeDefinition labels an enum; the
      // fields come from the enum type's member table.
      final value = DynamicValue(value: ptr.cast<ffi.Int32>().value, typeId: NodeId.int32);
      value.enumFields = nativeEnumFields(type);
      return value;
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_STRUCTURE:
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_OPTSTRUCT:
      return _decodeStructure(ptr, type, defs);
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_UNION:
      return _decodeUnion(ptr, type, defs);
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_DECIMAL:
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_BITFIELDCLUSTER:
      throw UnsupportedError('Cannot decode a ${t.typeKind} value ($typeId) from native memory');
  }
}

/// The enum fields of an enum `UA_DataType`: each member's `memberType` is
/// the value (a pointer-sized integer, not a pointer) and `memberName` its
/// name. The display name and description are not part of the native type and
/// are empty.
Map<int, EnumField> nativeEnumFields(ffi.Pointer<raw.UA_DataType> type) {
  final fields = <int, EnumField>{};
  final t = type.ref;
  for (var i = 0; i < t.membersSize; i++) {
    final member = t.members[i];
    // The generator stores the value in the pointer itself:
    // `.memberType = (const UA_DataType*)(uintptr_t)VALUE` (types_generated.c).
    final value = member.memberType.address;
    final name = member.memberName == ffi.nullptr ? '' : member.memberName.cast<Utf8>().toDartString();
    fields[value] = EnumField(value, name, LocalizedText('', ''), LocalizedText('', ''));
  }
  return fields;
}

/// The `UA_TYPES` entry whose `typeId` is [typeId] (an NS0 DataType the
/// bundled open62541 knows), or null. Built once; the table is static.
ffi.Pointer<raw.UA_DataType>? findNs0DataType(NodeId typeId) {
  if (typeId.namespace != 0 || !typeId.isNumeric()) return null;
  final index = _ns0TypeIndex[typeId.numeric];
  return index == null ? null : getTypeByIndex(index);
}

/// The binary encoding NodeId (`<Type>_Encoding_DefaultBinary`) of an NS0
/// structure open62541 knows, or null when [typeId] is not one. This is the
/// NodeId an ExtensionObject carrying the type must be encoded with.
NodeId? ns0BinaryEncodingId(NodeId typeId) {
  final type = findNs0DataType(typeId);
  if (type == null || !isNativeStructKind(type.ref.typeKind)) return null;
  return type.ref.binaryEncodingId.toNodeId();
}

/// The `UA_TYPES` entry whose `binaryEncodingId` is [encodingId] (the
/// `<Type>_Encoding_DefaultBinary` NodeId an ExtensionObject carries), or
/// null.
ffi.Pointer<raw.UA_DataType>? findNs0DataTypeByEncodingId(NodeId encodingId) {
  if (encodingId.namespace != 0 || !encodingId.isNumeric()) return null;
  final index = _ns0EncodingIndex[encodingId.numeric];
  return index == null ? null : getTypeByIndex(index);
}

/// Decodes [body], the binary encoding of a value of [type] (a `UA_TYPES`
/// entry), into a native struct and walks it with [decodeNative]. The struct
/// lives in a `ua_calloc`'d buffer of the type's `memSize` for the duration
/// of the walk; `UA_clear` releases what open62541 allocated into it (on a
/// failed decode open62541 has already cleared, and a second clear is a
/// no-op) and the buffer is freed, on every path. A decode that fails throws
/// a [UaStatusException] with open62541's status.
DynamicValue decodeEncodedKnown(raw.UA_String body, ffi.Pointer<raw.UA_DataType> type, {Schema? defs}) {
  // UA_decodeBinary takes the input by pointer: a scratch UA_ByteString over
  // the body's bytes (not a copy of them; it is only read).
  final input = ua_calloc<raw.UA_String>();
  input.ref.length = body.length;
  input.ref.data = body.data;
  final buffer = ua_calloc<ffi.Uint8>(type.ref.memSize).cast<ffi.Void>();
  try {
    final status = raw.UA_decodeBinary(input, buffer, type, ffi.nullptr);
    if (status != raw.UA_STATUSCODE_GOOD) {
      throw UaStatusException(status);
    }
    return decodeNative(buffer, type, defs: defs);
  } finally {
    raw.UA_clear(buffer, type);
    ua_calloc.free(buffer);
    ua_calloc.free(input);
  }
}

final Map<int, int> _ns0TypeIndex = () {
  final map = <int, int>{};
  for (var i = 0; i < raw.UA_TYPES_COUNT; i++) {
    final id = getTypeByIndex(i).ref.typeId;
    if (id.namespaceIndex == 0 && id.isNumeric()) {
      map[id.identifier.numeric] = i;
    }
  }
  return map;
}();

final Map<int, int> _ns0EncodingIndex = () {
  final map = <int, int>{};
  for (var i = 0; i < raw.UA_TYPES_COUNT; i++) {
    final type = getTypeByIndex(i).ref;
    final id = type.binaryEncodingId;
    // Only a structure has a binary encoding object; built-ins carry a null
    // encoding id (0), which must not map to anything.
    if (isNativeStructKind(type.typeKind) && id.namespaceIndex == 0 && id.isNumeric() && id.identifier.numeric != 0) {
      map[id.identifier.numeric] = i;
    }
  }
  return map;
}();

NodeId _builtinTypeId(raw.UA_DataTypeKind kind) {
  switch (kind) {
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_BOOLEAN:
      return NodeId.boolean;
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_SBYTE:
      return NodeId.sbyte;
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_BYTE:
      return NodeId.byte;
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_INT16:
      return NodeId.int16;
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_UINT16:
      return NodeId.uint16;
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_INT32:
      return NodeId.int32;
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_UINT32:
      return NodeId.uint32;
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_INT64:
      return NodeId.int64;
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_UINT64:
      return NodeId.uint64;
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_FLOAT:
      return NodeId.float;
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_DOUBLE:
      return NodeId.double;
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_DATETIME:
      return NodeId.datetime;
    default:
      throw ArgumentError('$kind is not a built-in scalar kind');
  }
}

DynamicValue _decodeStructure(ffi.Pointer<ffi.Void> ptr, ffi.Pointer<raw.UA_DataType> type, Schema? defs) {
  final t = type.ref;
  final value = DynamicValue(typeId: t.typeId.toNodeId());
  value.value = LinkedHashMap<String, DynamicValue>();
  value.extObjEncodingId = t.binaryEncodingId.toNodeId();
  var offset = 0;
  for (var i = 0; i < t.membersSize; i++) {
    final member = t.members[i];
    final memberType = member.memberType;
    offset += member.padding;
    final DynamicValue field;
    if (!member.isOptional) {
      if (!member.isArray) {
        field = decodeNative(ffi.Pointer.fromAddress(ptr.address + offset), memberType, defs: defs);
        offset += memberType.ref.memSize;
      } else {
        field = _decodeArrayMember(ptr.address + offset, memberType, defs);
        offset += ffi.sizeOf<ffi.Size>() + ffi.sizeOf<ffi.Pointer>();
      }
    } else if (!member.isArray) {
      final element = ffi.Pointer<ffi.Pointer<ffi.Void>>.fromAddress(ptr.address + offset).value;
      field = element == ffi.nullptr
          ? DynamicValue(typeId: memberType.ref.typeId.toNodeId())
          : decodeNative(element, memberType, defs: defs);
      offset += ffi.sizeOf<ffi.Pointer>();
    } else {
      final lengthAddress = ptr.address + offset;
      final elements = ffi.Pointer<ffi.Pointer<ffi.Void>>.fromAddress(lengthAddress + ffi.sizeOf<ffi.Size>()).value;
      field = elements == ffi.nullptr
          ? DynamicValue(typeId: memberType.ref.typeId.toNodeId())
          : _decodeArrayMember(lengthAddress, memberType, defs);
      offset += ffi.sizeOf<ffi.Size>() + ffi.sizeOf<ffi.Pointer>();
    }
    field.isOptional = member.isOptional;
    field.name = _memberName(member);
    value[field.name!] = field;
  }
  return value;
}

DynamicValue _decodeUnion(ffi.Pointer<ffi.Void> ptr, ffi.Pointer<raw.UA_DataType> type, Schema? defs) {
  final t = type.ref;
  final value = DynamicValue(typeId: t.typeId.toNodeId());
  value.value = LinkedHashMap<String, DynamicValue>();
  value.extObjEncodingId = t.binaryEncodingId.toNodeId();
  final selection = ptr.cast<ffi.Uint32>().value;
  if (selection == 0) return value;
  if (selection > t.membersSize) {
    throw StateError('Union ${value.typeId} selects member $selection of ${t.membersSize}');
  }
  final member = t.members[selection - 1];
  final memberType = member.memberType;
  // The padding of a union member is its offset from the start of the union
  // type (it includes the switch field).
  final address = ptr.address + member.padding;
  final field = member.isArray
      ? _decodeArrayMember(address, memberType, defs)
      : decodeNative(ffi.Pointer.fromAddress(address), memberType, defs: defs);
  field.name = _memberName(member);
  value[field.name!] = field;
  return value;
}

/// An array member at [lengthAddress]: the `size_t` length, then the pointer
/// to `length` elements of `memSize` bytes each.
DynamicValue _decodeArrayMember(int lengthAddress, ffi.Pointer<raw.UA_DataType> elementType, Schema? defs) {
  final length = ffi.Pointer<ffi.Size>.fromAddress(lengthAddress).value;
  final elements = ffi.Pointer<ffi.Pointer<ffi.Void>>.fromAddress(lengthAddress + ffi.sizeOf<ffi.Size>()).value;
  final list = DynamicValue(typeId: elementType.ref.typeId.toNodeId());
  list.value = <DynamicValue>[];
  if (length == 0 || elements == ffi.nullptr || elements.address == _emptyArraySentinel.address) {
    return list;
  }
  final memSize = elementType.ref.memSize;
  for (var i = 0; i < length; i++) {
    list[i] = decodeNative(ffi.Pointer.fromAddress(elements.address + i * memSize), elementType, defs: defs);
  }
  return list;
}

DynamicValue _decodeExtensionObject(raw.UA_ExtensionObject ext, Schema? defs) {
  switch (ext.encoding) {
    case raw.UA_ExtensionObjectEncoding.UA_EXTENSIONOBJECT_DECODED:
    case raw.UA_ExtensionObjectEncoding.UA_EXTENSIONOBJECT_DECODED_NODELETE:
      return decodeNative(ext.content.decoded.data, ext.content.decoded.type, defs: defs);
    case raw.UA_ExtensionObjectEncoding.UA_EXTENSIONOBJECT_ENCODED_NOBODY:
      return DynamicValue(typeId: NodeId.structure)..extObjEncodingId = ext.content.encoded.typeId.toNodeId();
    case raw.UA_ExtensionObjectEncoding.UA_EXTENSIONOBJECT_ENCODED_BYTESTRING:
    case raw.UA_ExtensionObjectEncoding.UA_EXTENSIONOBJECT_ENCODED_XML:
      final encodingId = ext.content.encoded.typeId.toNodeId();
      final isBinary = ext.encoding == raw.UA_ExtensionObjectEncoding.UA_EXTENSIONOBJECT_ENCODED_BYTESTRING;
      final schema = defs?[encodingId];
      if (schema != null && isBinary) {
        final value = OpcUaDynamicValueSerializer.deserialize(
          DynamicValue.from(schema),
          binarize.ByteReader(Uint8List.fromList(ext.content.encoded.body.asTypedList()), endian: Endian.little),
          Endian.little,
        );
        value.extObjEncodingId = encodingId;
        return value;
      }
      // A type the bundled open62541 knows: decode the body the way the
      // wire decoder would have.
      final known = isBinary ? findNs0DataTypeByEncodingId(encodingId) : null;
      if (known != null) {
        return decodeEncodedKnown(ext.content.encoded.body, known, defs: defs);
      }
      // Unknown type: keep the encoded body so nothing is lost.
      final body = Uint8List.fromList(ext.content.encoded.body.asTypedList());
      return DynamicValue(value: body, typeId: NodeId.structure)..extObjEncodingId = encodingId;
  }
}

/// `UA_DataValue` flag bits (the header's bitfield, replaced by the
/// `substitute` byte in the patched bindings): hasValue 0x01, hasStatus 0x02,
/// hasSourceTimestamp 0x04, hasServerTimestamp 0x08.
DynamicValue _decodeDataValue(raw.UA_DataValue dataValue, NodeId typeId, Schema? defs) {
  final flags = dataValue.substitute;
  final value = DynamicValue(typeId: typeId);
  value['Value'] = (flags & 0x01) != 0 ? variantToValue(dataValue.value, defs: defs) : DynamicValue();
  value['StatusCode'] = DynamicValue(
    value: (flags & 0x02) != 0 ? dataValue.status : raw.UA_STATUSCODE_GOOD,
    typeId: NodeId.fromNumeric(0, Namespace0Id.statusCode.value),
  );
  value['SourceTimestamp'] = DynamicValue(
    value: (flags & 0x04) != 0 ? uaDateTimeToDateTime(dataValue.sourceTimestamp) : null,
    typeId: NodeId.datetime,
  );
  value['ServerTimestamp'] = DynamicValue(
    value: (flags & 0x08) != 0 ? uaDateTimeToDateTime(dataValue.serverTimestamp) : null,
    typeId: NodeId.datetime,
  );
  return value;
}

/// `UA_DiagnosticInfo` flag bits (the header's bitfield, replaced by the
/// `substitute` byte in the patched bindings): hasSymbolicId 0x01,
/// hasNamespaceUri 0x02, hasLocalizedText 0x04, hasLocale 0x08,
/// hasAdditionalInfo 0x10, hasInnerStatusCode 0x20, hasInnerDiagnosticInfo
/// 0x40. A field whose flag is clear is null.
DynamicValue _decodeDiagnosticInfo(raw.UA_DiagnosticInfo info, NodeId typeId) {
  final flags = info.substitute;
  final value = DynamicValue(typeId: typeId);
  value['SymbolicId'] = DynamicValue(value: (flags & 0x01) != 0 ? info.symbolicId : null, typeId: NodeId.int32);
  value['NamespaceUri'] = DynamicValue(value: (flags & 0x02) != 0 ? info.namespaceUri : null, typeId: NodeId.int32);
  value['LocalizedText'] = DynamicValue(value: (flags & 0x04) != 0 ? info.localizedText : null, typeId: NodeId.int32);
  value['Locale'] = DynamicValue(value: (flags & 0x08) != 0 ? info.locale : null, typeId: NodeId.int32);
  value['AdditionalInfo'] = DynamicValue(
    value: (flags & 0x10) != 0 ? info.additionalInfo.value : null,
    typeId: NodeId.uastring,
  );
  value['InnerStatusCode'] = DynamicValue(
    value: (flags & 0x20) != 0 ? info.innerStatusCode : null,
    typeId: NodeId.fromNumeric(0, Namespace0Id.statusCode.value),
  );
  value['InnerDiagnosticInfo'] = (flags & 0x40) != 0 && info.innerDiagnosticInfo != ffi.nullptr
      ? _decodeDiagnosticInfo(info.innerDiagnosticInfo.ref, typeId)
      : DynamicValue(typeId: typeId);
  return value;
}

String _memberName(raw.UA_DataTypeMember member) {
  return member.memberName == ffi.nullptr ? '' : member.memberName.cast<Utf8>().toDartString();
}

extension _GuidText on raw.UA_Guid {
  /// The canonical lowercase text of this Guid (`xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`).
  String get text {
    String hex(int value, int width) => value.toRadixString(16).padLeft(width, '0');
    final tail = [for (var i = 2; i < 8; i++) hex(data4[i], 2)].join();
    return '${hex(data1, 8)}-${hex(data2, 4)}-${hex(data3, 4)}-${hex(data4[0], 2)}${hex(data4[1], 2)}-$tail';
  }
}
