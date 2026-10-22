import 'dart:ffi' as ffi;

import '../extensions.dart';
import '../third_party/open62541.g.dart' as raw;

final class _PadInt64 extends ffi.Struct {
  @ffi.Uint8()
  external int pad;
  @ffi.Int64()
  external int x;
}

final class _PadDouble extends ffi.Struct {
  @ffi.Uint8()
  external int pad;
  @ffi.Double()
  external double x;
}

final int _int64Align = ffi.sizeOf<_PadInt64>() - ffi.sizeOf<ffi.Int64>();
final int _doubleAlign = ffi.sizeOf<_PadDouble>() - ffi.sizeOf<ffi.Double>();
final int _pointerAlign = ffi.sizeOf<ffi.IntPtr>();

/// The C alignment of a value of [type] on this target, as open62541's
/// `type_alignment` (src/ua_types_definition.c) computes it: a structure is
/// aligned to its most aligned member, an array or optional member counting
/// as a `size_t` and a pointer.
int dataTypeAlignment(ffi.Pointer<raw.UA_DataType> type) {
  final kind = type.ref.typeKind;
  switch (kind) {
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_BOOLEAN:
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_SBYTE:
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_BYTE:
      return 1;
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_INT16:
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_UINT16:
      return 2;
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_INT32:
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_UINT32:
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_FLOAT:
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_GUID:
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_STATUSCODE:
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_ENUM:
      return 4;
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_INT64:
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_UINT64:
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_DATETIME:
      return _int64Align;
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_DOUBLE:
      return _doubleAlign;
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_DATAVALUE:
      return _int64Align > _pointerAlign ? _int64Align : _pointerAlign;
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_STRUCTURE:
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_OPTSTRUCT:
    case raw.UA_DataTypeKind.UA_DATATYPEKIND_UNION:
      var align = 1;
      for (var i = 0; i < type.ref.membersSize; i++) {
        final member = type.ref.members[i];
        final memberAlign = member.isArray || member.isOptional ? _pointerAlign : dataTypeAlignment(member.memberType);
        if (memberAlign > align) align = memberAlign;
      }
      return align;
    default:
      // String, ByteString, XmlElement, NodeId, ExpandedNodeId, QualifiedName,
      // LocalizedText, ExtensionObject, Variant, DiagnosticInfo: each holds a
      // pointer or a size_t, nothing wider.
      return _pointerAlign;
  }
}

/// Sets each member's `padding` and the `memSize` of the structure [type]
/// (kind STRUCTURE or OPTSTRUCT, members' `memberType`, `isArray` and
/// `isOptional` already set) to the C layout of the equivalent struct, as
/// `UA_DataType_fromStructureDescription` does: each member starts at the
/// next multiple of its alignment, and the size is rounded up to the
/// structure's alignment.
void layoutStructure(ffi.Pointer<raw.UA_DataType> type) {
  var offset = 0;
  for (var i = 0; i < type.ref.membersSize; i++) {
    final member = type.ref.members + i;
    final memberType = member.ref.memberType;
    final int align;
    final int size;
    if (member.ref.isArray) {
      align = _pointerAlign;
      size = ffi.sizeOf<ffi.Size>() + ffi.sizeOf<ffi.Pointer>();
    } else if (member.ref.isOptional) {
      align = _pointerAlign;
      size = ffi.sizeOf<ffi.Pointer>();
    } else {
      align = dataTypeAlignment(memberType);
      size = memberType.ref.memSize;
    }
    final padding = (align - offset % align) % align;
    member.ref.padding = padding;
    offset += padding + size;
  }
  final align = dataTypeAlignment(type);
  final memSize = offset == 0 ? 1 : offset + (align - offset % align) % align;
  if (memSize > 0xFFFF) {
    throw ArgumentError('${type.ref.membersSize} members take $memSize bytes, more than a UA_DataType can describe');
  }
  type.ref.memSize = memSize;
}
