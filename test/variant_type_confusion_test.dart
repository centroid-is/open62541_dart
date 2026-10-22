// A hostile server whose DataType attribute disagrees with the type it put on
// the wire must not make the client read native memory under the wrong layout.
//
// Client.read supplies the node's DataType attribute to the variant decoder as
// a hint. open62541 fills UA_Variant.type from the wire encoding byte. When the
// two disagree the decoder must key the native payload reader on the WIRE type
// and refuse a built-in/built-in disagreement with a typed UaTypeMismatch —
// never read the bytes under the hint. Before the fix a String hint over a
// 16-byte Guid read the Guid as a UA_String {size_t length; UA_Byte* data} and
// dereferenced the attacker-chosen pointer (an out-of-bounds native read).
//
// The server nodes are ordinary; a DataValueRewritingProxy swaps only the VALUE
// variant on the wire, same length, so open62541 decodes a different built-in
// while the DataType attribute still reports the original. read() is driven
// through both Client and ClientIsolate.

import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'data_value_rewriting_proxy.dart';

import 'common.dart'
    show clientTypes, setupClientOfType, setupServer, addBasicVariables, stringNodeId, intNodeId, readWrite;

// A String variable with a 4-character value, so its 9-byte wire variant
// (1 encoding byte + 4 length + 4 data) can be swapped for a scalar Double
// (1 + 8) without changing the message length.
final shortStringNodeId = NodeId.fromString(1, "the.shortString");

// The String variant body the server sends, keyed by the ASCII value so the
// needle is unique in the message: encoding byte 0x0c (built-in 12 = String),
// int32 length, then the bytes.
Uint8List _stringNeedle(String value) => Uint8List.fromList([0x0c, value.length, 0x00, 0x00, 0x00, ...value.codeUnits]);

// Scalar Guid variant, 17 bytes, same length as the "Hello World!" String body:
// encoding byte 0x0e (built-in 14 = Guid) + 16 bytes. The fix refuses before
// reading these bytes, so their content is irrelevant to the passing test; they
// are set to the {length: 64, pointer: 0xdeadbeef} a String hint would read, so
// that WITHOUT the fix the decoder dereferences 0xdeadbeef and the process dies
// (the mutation signal — a deterministic SEGV, not a catchable error).
Uint8List _guidScalar() {
  final body = ByteData(16);
  body.setUint64(0, 64, Endian.little); // "length"
  body.setUint64(8, 0xdeadbeef, Endian.little); // "pointer"
  return Uint8List.fromList([0x0e, ...body.buffer.asUint8List()]);
}

// Int32[3] variant, 17 bytes: array bit | built-in 6, int32 length 3, 3x4 bytes.
Uint8List _int32Array3() => Uint8List.fromList([0x86, 0x03, 0x00, 0x00, 0x00, ...List<int>.filled(12, 0x11)]);

// Scalar Double variant, 9 bytes, same length as a 4-char String body:
// encoding byte 0x0b (built-in 11 = Double) + 8 bytes.
Uint8List _doubleScalar() => Uint8List.fromList([0x0b, ...List<int>.filled(8, 0x00)]);

void main() {
  for (final clientType in clientTypes) {
    group('$clientType client: DataType hint disagrees with the wire type', () {
      late Server server;
      late DataValueRewritingProxy proxy;
      late ClientApi client;

      setUp(() async {
        server = setupServer();
        addBasicVariables(server); // stringNodeId = "Hello World!" (String), intNodeId = 1 (Int32)
        server.addVariableNode(
          shortStringNodeId,
          DynamicValue(value: "abcd", typeId: NodeId.uastring, name: "the.shortString"),
          accessLevel: readWrite,
        );
        proxy = await DataValueRewritingProxy.start(server.port);
        client = await setupClientOfType(clientType, 'opc.tcp://127.0.0.1:${proxy.port}');
      });

      tearDown(() async {
        await client.delete();
        await proxy.close();
        server.shutdown();
        server.delete();
      });

      /// Swap value [needle] for [replacement] (same length) on every message.
      void swapValue(Uint8List needle, Uint8List replacement) {
        proxy.rewriteMessage = (message) => replaceBytes(message, needle, replacement).$1;
      }

      /// After a refused read the client must still work: a clean node reads.
      Future<void> expectStillUsable() async {
        proxy.rewriteMessage = null;
        expect((await client.read(intNodeId)).value, 1);
      }

      test('read() refuses a String hint over a Guid wire value', () async {
        swapValue(_stringNeedle("Hello World!"), _guidScalar());
        await expectLater(
          client.read(stringNodeId),
          throwsA(
            isA<UaTypeMismatch>()
                .having((e) => e.expected.numeric, 'expected', 12) // String
                .having((e) => e.actual.numeric, 'actual', 14), // Guid
          ),
        );
        await expectStillUsable();
      }, timeout: const Timeout(Duration(seconds: 30)));

      test('read() refuses a String hint over an Int32 array wire value (element reader follows the wire)', () async {
        swapValue(_stringNeedle("Hello World!"), _int32Array3());
        await expectLater(
          client.read(stringNodeId),
          throwsA(
            isA<UaTypeMismatch>()
                .having((e) => e.expected.numeric, 'expected', 12) // String
                .having((e) => e.actual.numeric, 'actual', 6), // Int32
          ),
        );
        await expectStillUsable();
      }, timeout: const Timeout(Duration(seconds: 30)));

      test('read() refuses a String hint over a Double wire value', () async {
        swapValue(_stringNeedle("abcd"), _doubleScalar());
        await expectLater(
          client.read(shortStringNodeId),
          throwsA(
            isA<UaTypeMismatch>()
                .having((e) => e.expected.numeric, 'expected', 12) // String
                .having((e) => e.actual.numeric, 'actual', 11), // Double
          ),
        );
        await expectStillUsable();
      }, timeout: const Timeout(Duration(seconds: 30)));

      test('readValue() has no hint and stays safe on the same Guid wire value', () async {
        swapValue(_stringNeedle("Hello World!"), _guidScalar());
        // No DataType hint: the decoder keys on the wire type. Guid has no
        // payload reader, so it is a catchable error, never a native read.
        await expectLater(client.readValue(stringNodeId), throwsA(anything));
        await expectStillUsable();
      }, timeout: const Timeout(Duration(seconds: 30)));
    });
  }
}
