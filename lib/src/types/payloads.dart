import 'dart:convert';
import 'dart:ffi' as ffi;
import 'package:binarize/binarize.dart';
import 'package:ffi/ffi.dart';

import '../generated/open62541_bindings.dart' as raw;
// TODO this file has a lot of boilerplate, can we make it better?

class BooleanPayload extends PayloadType<bool> {
  const BooleanPayload();

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

// ignore: camel_case_types
class UA_SBytePayload extends PayloadType<raw.DartUA_SByte> {
  const UA_SBytePayload();

  @override
  raw.DartUA_SByte get(ByteReader reader, [Endian? endian]) {
    return reader.int8();
  }

  @override
  void set(ByteWriter writer, raw.DartUA_SByte value, [Endian? endian]) {
    writer.int8(value);
  }
}

// ignore: camel_case_types
class UA_Int16Payload extends PayloadType<raw.DartUA_Int16> {
  const UA_Int16Payload();

  @override
  raw.DartUA_Int16 get(ByteReader reader, [Endian? endian]) {
    return reader.int16(endian);
  }

  @override
  void set(ByteWriter writer, raw.DartUA_Int16 value, [Endian? endian]) {
    writer.int16(value, endian);
  }
}

// ignore: camel_case_types
class UA_Int32Payload extends PayloadType<raw.DartUA_Int32> {
  const UA_Int32Payload();

  @override
  raw.DartUA_Int32 get(ByteReader reader, [Endian? endian]) {
    return reader.int32(endian);
  }

  @override
  void set(ByteWriter writer, raw.DartUA_Int32 value, [Endian? endian]) {
    writer.int32(value, endian);
  }
}

// ignore: camel_case_types
class UA_Int64Payload extends PayloadType<raw.DartUA_Int64> {
  const UA_Int64Payload();

  @override
  raw.DartUA_Int64 get(ByteReader reader, [Endian? endian]) {
    return reader.int64(endian);
  }

  @override
  void set(ByteWriter writer, raw.DartUA_Int64 value, [Endian? endian]) {
    writer.int64(value, endian);
  }
}

// UInt

// ignore: camel_case_types
class UA_BytePayload extends PayloadType<raw.DartUA_Byte> {
  const UA_BytePayload();

  @override
  raw.DartUA_Byte get(ByteReader reader, [Endian? endian]) {
    return reader.uint8();
  }

  @override
  void set(ByteWriter writer, raw.DartUA_Byte value, [Endian? endian]) {
    writer.uint8(value);
  }
}

// ignore: camel_case_types
class UA_UInt16Payload extends PayloadType<raw.DartUA_UInt16> {
  const UA_UInt16Payload();

  @override
  raw.DartUA_UInt16 get(ByteReader reader, [Endian? endian]) {
    return reader.uint16(endian);
  }

  @override
  void set(ByteWriter writer, raw.DartUA_UInt16 value, [Endian? endian]) {
    writer.uint16(value, endian);
  }
}

// ignore: camel_case_types
class UA_UInt32Payload extends PayloadType<raw.DartUA_UInt32> {
  const UA_UInt32Payload();

  @override
  raw.DartUA_UInt32 get(ByteReader reader, [Endian? endian]) {
    return reader.uint32(endian);
  }

  @override
  void set(ByteWriter writer, raw.DartUA_UInt32 value, [Endian? endian]) {
    writer.uint32(value, endian);
  }
}

// ignore: camel_case_types
class UA_UInt64Payload extends PayloadType<raw.DartUA_UInt64> {
  const UA_UInt64Payload();

  @override
  raw.DartUA_UInt64 get(ByteReader reader, [Endian? endian]) {
    return reader.uint64(endian);
  }

  @override
  void set(ByteWriter writer, raw.DartUA_UInt64 value, [Endian? endian]) {
    writer.uint64(value, endian);
  }
}

// Float

// ignore: camel_case_types
class UA_FloatPayload extends PayloadType<raw.DartUA_Float> {
  const UA_FloatPayload();

  @override
  raw.DartUA_Float get(ByteReader reader, [Endian? endian]) {
    return reader.float32(endian);
  }

  @override
  void set(ByteWriter writer, raw.DartUA_Float value, [Endian? endian]) {
    writer.float32(value, endian);
  }
}

// ignore: camel_case_types
class UA_DoublePayload extends PayloadType<raw.DartUA_Double> {
  const UA_DoublePayload();

  @override
  raw.DartUA_Double get(ByteReader reader, [Endian? endian]) {
    return reader.float64(endian);
  }

  @override
  void set(ByteWriter writer, raw.DartUA_Double value, [Endian? endian]) {
    writer.float64(value, endian);
  }
}

// Other

// ignore: camel_case_types
class UA_DateTimePayload extends PayloadType<DateTime> {
  const UA_DateTimePayload();

  static final opcuaEpoch = DateTime.utc(1601, 1, 1, 0, 0, 0);
  static final maxint = 9223372036854775807;

  @override
  DateTime get(ByteReader reader, [Endian? endian]) {
    final dateTimeRaw = reader.int64(endian);
    if (dateTimeRaw == 0 /* Don't have to check platform, it goes earlier then opcua epoch*/) {
      return DateTime(-271821, 04, 20);
    } else if (dateTimeRaw == maxint) {
      return DateTime(275760, 09, 13);
    } else {
      final sinceEpoch = Duration(microseconds: dateTimeRaw ~/ 10);
      return opcuaEpoch.add(sinceEpoch);
    }
  }

  @override
  void set(ByteWriter writer, DateTime value, [Endian? endian]) {
    if (value.isBefore(
      opcuaEpoch,
    ) /* Eearliest representable by development platform is lower then opcua epoch. Don't need to check it. */) {
      writer.int64(0, endian);
    } else if (value.isAfter(DateTime(9999, 12, 31, 11, 59, 58, 999, 999))) {
      writer.int64(maxint, endian);
    } else {
      final difference = value.difference(opcuaEpoch);
      writer.int64(difference.inMicroseconds * 10, endian);
    }
  }
}

// typedef UA_StatusCode = ffi.Uint32;
// typedef DartUA_StatusCode = int;

// ignore: camel_case_types
class UA_StringPayload extends PayloadType<String> {
  const UA_StringPayload();

  @override
  String get(ByteReader reader, [Endian? endian]) {
    final lengthSize = ffi.sizeOf<ffi.Size>();
    final length = lengthSize == 4 ? reader.int32(endian) : reader.int64(endian);
    final ptrValue = lengthSize == 4 ? reader.uint32(endian) : reader.uint64(endian);
    if (length <= 0) return '';
    final ptr = ffi.Pointer<raw.UA_Byte>.fromAddress(ptrValue);
    final buffer = ptr.asTypedList(length);
    return utf8.decode(buffer);
  }

  @override
  void set(ByteWriter writer, String value, [Endian? endian]) {
    final buffer = utf8.encode(value);
    ffi.Pointer<ffi.Char> heap = calloc(buffer.length);
    for (int i = 0; i < buffer.length; i++) {
      heap[i] = buffer[i];
    }
    final lengthSize = ffi.sizeOf<ffi.Size>();
    if (lengthSize == 4) {
      writer.int32(buffer.length, endian);
      writer.int32(heap.address, endian);
    } else {
      writer.int64(buffer.length, endian);
      writer.int64(heap.address, endian);
    }
  }
}

class ContiguousStringPayload extends PayloadType<String?> {
  const ContiguousStringPayload();

  @override
  String? get(ByteReader reader, [Endian? endian]) {
    final length = UA_Int32Payload().get(reader, endian);
    if (length == -1) return null;
    if (length == 0) return '';
    final bytes = reader.read(length);
    return utf8.decode(bytes);
  }

  @override
  void set(ByteWriter writer, String? value, [Endian? endian]) {
    if (value == null) {
      UA_Int32Payload().set(writer, -1, endian);
    } else {
      final bytes = utf8.encode(value);
      UA_Int32Payload().set(writer, bytes.length, endian);
      writer.write(bytes);
    }
  }
}
