import 'dart:convert';
import 'dart:ffi';

import 'package:binarize/binarize.dart';
import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

import 'package:open62541/src/generated/open62541_bindings.dart' as raw;
import 'package:open62541/src/types/payloads.dart';

void main() {
  void testPayloadImpl<T>(String name, PayloadType<T> payload, T value) {
    final writer = ByteWriter();
    payload.set(writer, value);

    final reader = ByteReader(writer.toBytes());
    final result = payload.get(reader);

    expect(result, value);
  }

  void testPayload<T>(String name, PayloadType<T> payload, T value) {
    test('$name payload', () {
      testPayloadImpl(name, payload, value);
    });
  }

  // Boolean
  testPayload('Boolean true', BooleanPayload(), true);
  testPayload('Boolean false', BooleanPayload(), false);

  // Signed integers
  testPayload('SByte min', UA_SBytePayload(), -128);
  testPayload('SByte max', UA_SBytePayload(), 127);

  testPayload('Int16 min', UA_Int16Payload(), -32768);
  testPayload('Int16 max', UA_Int16Payload(), 32767);

  testPayload('Int32 min', UA_Int32Payload(), -2147483648);
  testPayload('Int32 max', UA_Int32Payload(), 2147483647);

  testPayload('Int64 min', UA_Int64Payload(), -9223372036854775808);
  testPayload('Int64 max', UA_Int64Payload(), 9223372036854775807);

  // Unsigned integers
  testPayload('Byte min', UA_BytePayload(), 0);
  testPayload('Byte max', UA_BytePayload(), 255);

  testPayload('UInt16 min', UA_UInt16Payload(), 0);
  testPayload('UInt16 max', UA_UInt16Payload(), 65535);

  testPayload('UInt32 min', UA_UInt32Payload(), 0);
  testPayload('UInt32 max', UA_UInt32Payload(), 4294967295);

  testPayload('UInt64 min', UA_UInt64Payload(), 0);
  testPayload('UInt64 (dart) max as in int64', UA_UInt64Payload(), 9223372036854775807);

  // Floating point
  testPayload('Double positive', UA_DoublePayload(), 3.14159265359);
  testPayload('Double negative', UA_DoublePayload(), -3.14159265359);
  testPayload('Double zero', UA_DoublePayload(), 0.0);
  test('Float payload', () {
    final payload = UA_FloatPayload();
    final writer = ByteWriter();

    // Test normal float with precision check
    final float = 3.14159;
    payload.set(writer, float);
    final reader = ByteReader(writer.toBytes());
    final result = payload.get(reader);
    expect(result, closeTo(float, 1e-6));

    // Test negative
    writer.clear();
    payload.set(writer, -float);
    expect(payload.get(ByteReader(writer.toBytes())), closeTo(-float, 1e-6));

    // Test zero
    writer.clear();
    payload.set(writer, 0.0);
    expect(payload.get(ByteReader(writer.toBytes())), 0.0);
  });

  // String
  testPayload('String normal', ContiguousStringPayload(), 'Hello, World!');

  // Test empty string
  testPayload('String empty', ContiguousStringPayload(), '');

  // Test null string
  testPayload('String null', ContiguousStringPayload(), null);

  // Test UTF-8 characters
  testPayload('String UTF-8', ContiguousStringPayload(), '🌟 Hello 世界');

  test('DateTime payload', () {
    final payload = UA_DateTimePayload();

    // Test a known date/time value
    final writer = ByteWriter();
    final originalDate = DateTime.utc(2024, 3, 14, 15, 9, 26, 535);
    payload.set(writer, originalDate);

    final reader = ByteReader(writer.toBytes());
    final convertedDate = payload.get(reader);

    expect(convertedDate, originalDate);
    expect(convertedDate.millisecondsSinceEpoch, originalDate.millisecondsSinceEpoch);

    // Test specific components
    expect(convertedDate.year, 2024);
    expect(convertedDate.month, 3);
    expect(convertedDate.day, 14);
    expect(convertedDate.hour, 15);
    expect(convertedDate.minute, 9);
    expect(convertedDate.second, 26);
    expect(convertedDate.millisecond, 535);
  });

  test('UA_String payload', () {
    final payload = UA_StringPayload();
    final writer = ByteWriter();

    final testStr = '🌟 Hello 世界';
    final bytes = utf8.encode(testStr);
    final dataPtr = calloc<raw.UA_Byte>(bytes.length);
    dataPtr.asTypedList(bytes.length).setAll(0, bytes);

    // Write length and pointer
    final lengthSize = sizeOf<Size>();
    if (lengthSize == 4) {
      writer.int32(bytes.length);
      writer.uint32(dataPtr.address);
    } else {
      writer.int64(bytes.length);
      writer.uint64(dataPtr.address);
    }

    final reader = ByteReader(writer.toBytes());
    final result = payload.get(reader);
    expect(result, testStr);

    // Cleanup
    calloc.free(dataPtr);
  });
}
