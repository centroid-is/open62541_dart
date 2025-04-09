import 'package:ffi/ffi.dart';
import 'package:binarize/binarize.dart';
import 'dart:convert';
import 'dart:ffi' as ffi;

import 'abstract.dart';
import '../extensions.dart';
import '../generated/open62541_bindings.dart' as raw;
import '../nodeId.dart';

class BooleanPayload extends PayloadType<bool> with MixinNodeIdType {
  const BooleanPayload();

  @override
  NodeId get nodeIdType => NodeId.numeric(0, Namespace0Id.boolean.value);

  @override
  bool get(ByteReader reader, [Endian? endian]) {
    return reader.uint8() != 0;
  }

  @override
  void set(ByteWriter writer, bool value, [Endian? endian]) {
    writer.uint8(value ? 1 : 0);
  }
}

// Int

class UA_SBytePayload extends PayloadType<raw.DartUA_SByte>
    with MixinNodeIdType {
  const UA_SBytePayload();

  @override
  NodeId get nodeIdType => NodeId.numeric(0, Namespace0Id.sbyte.value);

  @override
  raw.DartUA_SByte get(ByteReader reader, [Endian? endian]) {
    return reader.int8();
  }

  @override
  void set(ByteWriter writer, raw.DartUA_SByte value, [Endian? endian]) {
    writer.int8(value);
  }
}

class UA_Int16Payload extends PayloadType<raw.DartUA_Int16>
    with MixinNodeIdType {
  const UA_Int16Payload();

  @override
  NodeId get nodeIdType => NodeId.numeric(0, Namespace0Id.int16.value);

  @override
  raw.DartUA_Int16 get(ByteReader reader, [Endian? endian]) {
    return reader.int16();
  }

  @override
  void set(ByteWriter writer, raw.DartUA_Int16 value, [Endian? endian]) {
    writer.int16(value);
  }
}

class UA_Int32Payload extends PayloadType<raw.DartUA_Int32>
    with MixinNodeIdType {
  const UA_Int32Payload();

  @override
  NodeId get nodeIdType => NodeId.numeric(0, Namespace0Id.int32.value);

  @override
  raw.DartUA_Int32 get(ByteReader reader, [Endian? endian]) {
    return reader.int32();
  }

  @override
  void set(ByteWriter writer, raw.DartUA_Int32 value, [Endian? endian]) {
    writer.int32(value);
  }
}

class UA_Int64Payload extends PayloadType<raw.DartUA_Int64>
    with MixinNodeIdType {
  const UA_Int64Payload();

  @override
  NodeId get nodeIdType => NodeId.numeric(0, Namespace0Id.int64.value);

  @override
  raw.DartUA_Int64 get(ByteReader reader, [Endian? endian]) {
    return reader.int64();
  }

  @override
  void set(ByteWriter writer, raw.DartUA_Int64 value, [Endian? endian]) {
    writer.int64(value);
  }
}

// UInt

class UA_BytePayload extends PayloadType<raw.DartUA_Byte> with MixinNodeIdType {
  const UA_BytePayload();

  @override
  NodeId get nodeIdType => NodeId.numeric(0, Namespace0Id.byte.value);

  @override
  raw.DartUA_Byte get(ByteReader reader, [Endian? endian]) {
    return reader.uint8();
  }

  @override
  void set(ByteWriter writer, raw.DartUA_Byte value, [Endian? endian]) {
    writer.uint8(value);
  }
}

class UA_UInt16Payload extends PayloadType<raw.DartUA_UInt16>
    with MixinNodeIdType {
  const UA_UInt16Payload();

  @override
  NodeId get nodeIdType => NodeId.numeric(0, Namespace0Id.uint16.value);

  @override
  raw.DartUA_UInt16 get(ByteReader reader, [Endian? endian]) {
    return reader.uint16();
  }

  @override
  void set(ByteWriter writer, raw.DartUA_UInt16 value, [Endian? endian]) {
    writer.uint16(value);
  }
}

class UA_UInt32Payload extends PayloadType<raw.DartUA_UInt32>
    with MixinNodeIdType {
  const UA_UInt32Payload();

  @override
  NodeId get nodeIdType => NodeId.numeric(0, Namespace0Id.uint32.value);

  @override
  raw.DartUA_UInt32 get(ByteReader reader, [Endian? endian]) {
    return reader.uint32();
  }

  @override
  void set(ByteWriter writer, raw.DartUA_UInt32 value, [Endian? endian]) {
    writer.uint32(value);
  }
}

class UA_UInt64Payload extends PayloadType<raw.DartUA_UInt64>
    with MixinNodeIdType {
  const UA_UInt64Payload();

  @override
  NodeId get nodeIdType => NodeId.numeric(0, Namespace0Id.uint64.value);

  @override
  raw.DartUA_UInt64 get(ByteReader reader, [Endian? endian]) {
    return reader.uint64();
  }

  @override
  void set(ByteWriter writer, raw.DartUA_UInt64 value, [Endian? endian]) {
    writer.uint64(value);
  }
}

// typedef UA_Float = ffi.Float;
// typedef DartUA_Float = double;

// typedef UA_Int16 = ffi.Int16;
// typedef DartUA_Int16 = int;
// typedef UA_DateTime = ffi.Int64;
// typedef DartUA_DateTime = int;
// typedef UA_Double = ffi.Double;
// typedef DartUA_Double = double;
// typedef UA_UInt16 = ffi.Uint16;
// typedef DartUA_UInt16 = int;
// typedef UA_UInt32 = ffi.Uint32;
// typedef DartUA_UInt32 = int;
// typedef UA_StatusCode = ffi.Uint32;
// typedef DartUA_StatusCode = int;
// typedef UA_Int64 = ffi.Int64;
// typedef DartUA_Int64 = int;
// typedef UA_UInt64 = ffi.Uint64;
// typedef DartUA_UInt64 = int;

// final class UA_DataTypeArray extends ffi.Struct {
//   external ffi.Pointer<UA_DataTypeArray> next;

//   @ffi.Size()
//   external int typesSize;

//   external ffi.Pointer<UA_DataType> types;

//   @ffi.Bool()
//   external bool cleanup;
// }
