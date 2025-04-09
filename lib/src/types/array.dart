import 'package:ffi/ffi.dart';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'package:binarize/binarize.dart';

import '../extensions.dart';
import 'abstract.dart';
import 'string.dart';
import 'trivial.dart';
import '../nodeId.dart';

class ArrayPayload<T> extends PayloadType<List<T>?> with MixinNodeIdType {
  final PayloadType<T> elementType;
  const ArrayPayload(this.elementType);

  @override

  /// BIG TODO
  NodeId get nodeIdType => NodeId.numeric(0, Namespace0Id.boolean.value);

  @override
  List<T>? get(ByteReader reader, [Endian? endian]) {
    final length = UA_UInt16Payload().get(reader, endian);
    if (length == 0) return null;
    List<T> elements = [];
    for (int i = 0; i < length; i++) {
      elements.add(elementType.get(reader, endian));
    }
    return elements;
  }

  @override
  void set(ByteWriter writer, List<T>? value, [Endian? endian]) {
    if (value == null) {
      UA_UInt16Payload().set(writer, -1, endian);
    } else {
      UA_UInt16Payload().set(writer, value.length, endian);
      for (var element in value) {
        elementType.set(writer, element, endian);
      }
    }
  }
}

const arrayStringPayload = ArrayPayload<String?>(StringPayload());
const arraySbytePayload = ArrayPayload<int>(UA_SBytePayload());
const arrayInt16Payload = ArrayPayload<int>(UA_Int16Payload());
const arrayInt32Payload = ArrayPayload<int>(UA_Int32Payload());
const arrayInt64Payload = ArrayPayload<int>(UA_Int64Payload());
// todo more
