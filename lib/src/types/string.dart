import 'package:ffi/ffi.dart';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'package:binarize/binarize.dart';

import '../generated/open62541_bindings.dart' as raw;
import '../extensions.dart';
import 'abstract.dart';
import 'trivial.dart';
import '../nodeId.dart';

// ignore: camel_case_extensions
extension UA_StringExtension on raw.UA_String {
  void set(String value) {
    free();
    final bytes = utf8.encode(value);
    final dataPtr = calloc<ffi.Uint8>(bytes.length);

    final byteList = dataPtr.asTypedList(bytes.length);
    byteList.setAll(0, bytes);

    length = bytes.length;
    data = dataPtr;
  }

  String get value {
    final bytes = data.asTypedList(length);
    return utf8.decode(bytes);
  }

  Iterable<int> get dataIterable => data.asTypedList(length);

  void free() {
    if (data != ffi.nullptr) {
      calloc.free(data);
      data = ffi.nullptr;
      length = 0;
    }
  }
}

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
