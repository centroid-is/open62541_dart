import 'dart:convert';
import 'package:binarize/binarize.dart';

import '../extensions.dart';
import 'abstract.dart';
import '../nodeId.dart';
import '../generated/open62541_bindings.dart' as raw;

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

// ignore: camel_case_types
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

// ignore: camel_case_types
class UA_Int16Payload extends PayloadType<raw.DartUA_Int16>
    with MixinNodeIdType {
  const UA_Int16Payload();

  @override
  NodeId get nodeIdType => NodeId.numeric(0, Namespace0Id.int16.value);

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
class UA_Int32Payload extends PayloadType<raw.DartUA_Int32>
    with MixinNodeIdType {
  const UA_Int32Payload();

  @override
  NodeId get nodeIdType => NodeId.numeric(0, Namespace0Id.int32.value);

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
class UA_Int64Payload extends PayloadType<raw.DartUA_Int64>
    with MixinNodeIdType {
  const UA_Int64Payload();

  @override
  NodeId get nodeIdType => NodeId.numeric(0, Namespace0Id.int64.value);

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

// ignore: camel_case_types
class UA_UInt16Payload extends PayloadType<raw.DartUA_UInt16>
    with MixinNodeIdType {
  const UA_UInt16Payload();

  @override
  NodeId get nodeIdType => NodeId.numeric(0, Namespace0Id.uint16.value);

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
class UA_UInt32Payload extends PayloadType<raw.DartUA_UInt32>
    with MixinNodeIdType {
  const UA_UInt32Payload();

  @override
  NodeId get nodeIdType => NodeId.numeric(0, Namespace0Id.uint32.value);

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
class UA_UInt64Payload extends PayloadType<raw.DartUA_UInt64>
    with MixinNodeIdType {
  const UA_UInt64Payload();

  @override
  NodeId get nodeIdType => NodeId.numeric(0, Namespace0Id.uint64.value);

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
class UA_FloatPayload extends PayloadType<raw.DartUA_Float>
    with MixinNodeIdType {
  const UA_FloatPayload();

  @override
  NodeId get nodeIdType => NodeId.numeric(0, Namespace0Id.float.value);

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
class UA_DoublePayload extends PayloadType<raw.DartUA_Double>
    with MixinNodeIdType {
  const UA_DoublePayload();

  @override
  NodeId get nodeIdType => NodeId.numeric(0, Namespace0Id.double.value);

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
class UA_DateTimePayload extends PayloadType<DateTime> with MixinNodeIdType {
  const UA_DateTimePayload();

  @override
  NodeId get nodeIdType => NodeId.numeric(0, Namespace0Id.dateTime.value);

  static const uaDatetimeSec = 10000000;
  static const uaDatetimeUnixEpoch = 116444736000000000;

  DateTime _opcuaToDateTime(int t) {
    // Convert to seconds since Unix epoch using the same logic as the C code
    final secSinceUnixEpoch =
        (t ~/ uaDatetimeSec) - (uaDatetimeUnixEpoch ~/ uaDatetimeSec);

    // Handle fractional part
    var frac = t % uaDatetimeSec;
    if (frac < 0) {
      frac += uaDatetimeSec;
    }

    // Convert seconds to DateTime
    final millisSinceEpoch =
        secSinceUnixEpoch * 1000 + ((frac % 10000000) ~/ 10000);

    return DateTime.fromMillisecondsSinceEpoch(millisSinceEpoch);
  }

  @override
  DateTime get(ByteReader reader, [Endian? endian]) {
    return _opcuaToDateTime(reader.int64(endian));
  }

  @override
  void set(ByteWriter writer, DateTime value, [Endian? endian]) {
    final millisSinceEpoch = value.millisecondsSinceEpoch;
    final t = (millisSinceEpoch ~/ 1000) * uaDatetimeSec +
        uaDatetimeUnixEpoch +
        (millisSinceEpoch % 1000) * 10000;
    writer.int64(t, endian);
  }
}
// typedef UA_DateTime = ffi.Int64;
// typedef DartUA_DateTime = int;
// typedef UA_StatusCode = ffi.Uint32;
// typedef DartUA_StatusCode = int;

class StringPayload extends PayloadType<String?> with MixinNodeIdType {
  const StringPayload();

  @override
  NodeId get nodeIdType => NodeId.numeric(0, Namespace0Id.string.value);

  @override
  String? get(ByteReader reader, [Endian? endian]) {
    final length = UA_UInt16Payload().get(reader, endian);
    if (length == 0) return null;
    return reader.read(length).toString();
  }

  @override
  void set(ByteWriter writer, String? value, [Endian? endian]) {
    if (value == null) {
      UA_UInt16Payload().set(writer, -1, endian);
    } else {
      UA_UInt16Payload().set(writer, value.length, endian);
      writer.write(Uint8List.fromList(utf8.encode(value)));
    }
  }
}

class ArrayPayload<T> extends PayloadType<List<T>?> {
  final PayloadType<T> elementType;
  int? length;
  // Supplying length will skip decoding it from the binary buffer,
  // When an array is monitored directly, the length is not supplied in the binary buffer.
  // Dont ask me why.
  ArrayPayload(this.elementType, [this.length]);

  @override
  List<T>? get(ByteReader reader, [Endian? endian]) {
    // BIG TODO, IS THIS CORRECT? I dont like this
    final len = length ?? UA_Int32Payload().get(reader, endian);
    if (len == -1) return null;
    if (len == 0) return [];
    List<T> elements = [];
    for (int i = 0; i < len; i++) {
      elements.add(elementType.get(reader, endian));
    }
    return elements;
  }

  @override
  void set(ByteWriter writer, List<T>? value, [Endian? endian]) {
    if (value == null) {
      UA_Int32Payload().set(writer, -1, endian);
    } else {
      UA_Int32Payload().set(writer, value.length, endian);
      for (var element in value) {
        elementType.set(writer, element, endian);
      }
    }
  }
}
