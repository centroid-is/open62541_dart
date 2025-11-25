import 'dart:ffi' as ffi;
import '' as self;

typedef UA_UInt32 = ffi.Uint32;
typedef UA_Int32 = ffi.Int32;
typedef UA_UInt16 = ffi.Uint16;
typedef UA_Byte = ffi.Uint8;
final class UA_Guid extends ffi.Struct {
  @UA_UInt32()
  external int data1;

  @UA_UInt16()
  external int data2;

  @UA_UInt16()
  external int data3;

  @ffi.Array.multi([8])
  external ffi.Array<UA_Byte> data4;
}
final class UA_String extends ffi.Struct {
  @ffi.Size()
  external int length;

  external ffi.Pointer<UA_Byte> data;
}

final class UnnamedUnion extends ffi.Union {
  @UA_UInt32()
  external int numeric;

  external UA_String string;

  external UA_Guid guid;
}

enum UA_NodeIdType {
  UA_NODEIDTYPE_NUMERIC(0),
  UA_NODEIDTYPE_STRING(3),
  UA_NODEIDTYPE_GUID(4),
  UA_NODEIDTYPE_BYTESTRING(5);

  final int value;
  const UA_NodeIdType(this.value);

  static UA_NodeIdType fromValue(int value) => switch (value) {
    0 => UA_NODEIDTYPE_NUMERIC,
    3 => UA_NODEIDTYPE_STRING,
    4 => UA_NODEIDTYPE_GUID,
    5 => UA_NODEIDTYPE_BYTESTRING,
    _ => throw ArgumentError('Unknown value for UA_NodeIdType: $value'),
  };
}
final class UA_NodeId extends ffi.Struct {
  @UA_UInt16()
  external int namespaceIndex;

  @ffi.UnsignedInt()
  external int identifierTypeAsInt;

  UA_NodeIdType get identifierType => UA_NodeIdType.fromValue(identifierTypeAsInt);

  external UnnamedUnion identifier;
}

final class UA_DataTypeMember extends ffi.Struct {
  external ffi.Pointer<ffi.Char> memberName;

  external ffi.Pointer<UA_DataType> memberType;

  @UA_Byte()
  external int substitute;
}
final class UA_DataType extends ffi.Struct {
  external ffi.Pointer<ffi.Char> typeName;

  external UA_NodeId typeId;

  external UA_NodeId binaryEncodingId;

  external UA_NodeId xmlEncodingId;

  @UA_UInt32()
  external int substitute;

  external ffi.Pointer<UA_DataTypeMember> members;
}

@ffi.Array.multi([388])
@ffi.Native<ffi.Array<UA_DataType>>()
external ffi.Array<UA_DataType> UA_TYPES;