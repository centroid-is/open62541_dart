// A struct's array member carries its length on the wire as an Int32 the
// server chose. OpcUaDynamicValueSerializer.deserialize used to size the
// member from it before reading a single element and with no bound against
// the bytes left: a 4-byte body claiming 20,000,000 elements had the template
// cloned 20,000,000 times, and one claiming 2^31-1 ended in an uncatchable
// OutOfMemoryError that takes the isolate with it (for ClientIsolate, the
// isolate that owns the connection). Any server a client reads a custom
// struct from can serve such a body.
//
// Now (Part 6 5.2.5, and what open62541's own Array_decodeBinary does): a
// negative length is a null array and decodes as an empty one, a length
// greater than the bytes left is refused with a FormatException at the
// length's offset before anything is sized by it, and the elements are
// decoded one at a time into a list that grows with them.
//
// Fixtures
//   The unit tests feed the public `deserialize` a struct body directly. The
//   end-to-end tests put DataValueRewritingProxy in front of an in-process
//   Server that serves a custom struct with an Int32[] member and overwrite
//   the member's length in the ReadResponse on its way to the client (the
//   Dart server cannot produce the body: it writes the real length).
//
// Red/green
//   Without the guard the unit tests die (OutOfMemoryError for 2^31-1, a
//   RangeError after 20,000,000 clones) and the end-to-end reads fail with
//   a RangeError instead of the decode error, after cloning 2^31-1 elements
//   or dying trying.

import 'package:binarize/binarize.dart';
import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart';
import 'data_value_rewriting_proxy.dart';

/// The schema `fromDataTypeDefinition` builds for `{values: Int32[], after:
/// Int32}`: the array member seeded with a single template element.
DynamicValue int32ArraySchema() {
  final s = DynamicValue(typeId: NodeId.fromString(1, 'ST_Guard'));
  s['values'] = DynamicValue.fromList([DynamicValue(typeId: NodeId.int32)], typeId: NodeId.int32);
  s['after'] = DynamicValue(typeId: NodeId.int32);
  return s;
}

/// `{flags: Boolean[]}`: one byte per element, so a length can equal the
/// bytes left exactly.
DynamicValue booleanArraySchema() {
  final s = DynamicValue(typeId: NodeId.fromString(1, 'ST_Flags'));
  s['flags'] = DynamicValue.fromList([DynamicValue(typeId: NodeId.boolean)], typeId: NodeId.boolean);
  return s;
}

/// `{items: ST_Item[]}` where `ST_Item` is `{flag: Boolean, n: Int32}`.
DynamicValue structArraySchema() {
  final item = DynamicValue(typeId: NodeId.fromString(1, 'ST_Item'));
  item['flag'] = DynamicValue(typeId: NodeId.boolean);
  item['n'] = DynamicValue(typeId: NodeId.int32);
  final s = DynamicValue(typeId: NodeId.fromString(1, 'ST_Items'));
  s['items'] = DynamicValue.fromList([item], typeId: item.typeId);
  return s;
}

Uint8List int32s(List<int> values) {
  final bytes = ByteData(values.length * 4);
  for (var i = 0; i < values.length; i++) {
    bytes.setInt32(i * 4, values[i], Endian.little);
  }
  return bytes.buffer.asUint8List();
}

/// Decodes [body] as the struct body of [schema] (no ExtensionObject header).
DynamicValue decodeBody(DynamicValue schema, Uint8List body) {
  return OpcUaDynamicValueSerializer.deserialize(schema, ByteReader(body, endian: Endian.little), Endian.little, true);
}

void main() {
  group('deserialize of a struct array member', () {
    for (final claimed in [0x7FFFFFFF, 20000000]) {
      test('a 4-byte body claiming $claimed elements is refused at once, before anything is sized by it', () {
        final body = int32s([claimed]);
        final watch = Stopwatch()..start();
        expect(
          () => decodeBody(int32ArraySchema(), body),
          throwsA(
            isA<FormatException>()
                .having((e) => e.offset, 'offset', 0)
                .having((e) => e.message, 'message', 'Array length $claimed exceeds the 0 bytes left in the buffer'),
          ),
        );
        expect(watch.elapsed, lessThan(const Duration(seconds: 1)), reason: 'nothing was cloned $claimed times');
      });
    }

    test('a length one past the bytes left is refused at the length\'s offset', () {
      // flags: 4 claimed, 3 bytes follow.
      final body = Uint8List.fromList([4, 0, 0, 0, 1, 0, 1]);
      expect(
        () => decodeBody(booleanArraySchema(), body),
        throwsA(isA<FormatException>().having((e) => e.offset, 'offset', 0)),
      );
      // After a leading field, the offset is the length's, not 0.
      final lead = booleanArraySchema();
      lead.value = {'lead': DynamicValue(typeId: NodeId.int32), ...lead.asObject};
      expect(
        () => decodeBody(lead, Uint8List.fromList([7, 0, 0, 0, 9, 0, 0, 0, 1, 0])),
        throwsA(
          isA<FormatException>()
              .having((e) => e.offset, 'offset', 4)
              .having((e) => e.message, 'message', 'Array length 9 exceeds the 2 bytes left in the buffer'),
        ),
      );
    });

    test('a length equal to the bytes left, one byte per element, decodes', () {
      final value = decodeBody(booleanArraySchema(), Uint8List.fromList([3, 0, 0, 0, 1, 0, 1]));
      expect(value['flags'].asArray.map((e) => e.value).toList(), [true, false, true]);
    });

    test('-1 is a null array: decoded as empty, the field after it is read where it is', () {
      final value = decodeBody(int32ArraySchema(), int32s([-1, 42]));
      expect(value['values'].isArray, isTrue);
      expect(value['values'].asArray, isEmpty);
      expect(value['after'].value, 42);
    });

    test('a correct body round-trips', () {
      final schema = int32ArraySchema();
      final original = int32ArraySchema();
      original['values'] = DynamicValue.fromList([
        for (final n in [1, 2, 3]) DynamicValue(value: n, typeId: NodeId.int32),
      ], typeId: NodeId.int32);
      original['after'].value = 42;
      final writer = ByteWriter();
      OpcUaDynamicValueSerializer.serialize(original, writer, original, Endian.little, true);
      final body = writer.toBytes();
      expect(body, int32s([3, 1, 2, 3, 42]));

      final value = decodeBody(schema, body);
      expect(value['values'].asArray.map((e) => e.value).toList(), [1, 2, 3]);
      expect(value['after'].value, 42);
    });

    test('an array of structs decodes element by element and a hostile length is refused', () {
      final value = decodeBody(structArraySchema(), Uint8List.fromList([2, 0, 0, 0, 1, 7, 0, 0, 0, 0, 9, 0, 0, 0]));
      final items = value['items'].asArray;
      expect(items, hasLength(2));
      expect(items[0]['flag'].value, isTrue);
      expect(items[0]['n'].value, 7);
      expect(items[1]['flag'].value, isFalse);
      expect(items[1]['n'].value, 9);
      expect(
        () => decodeBody(structArraySchema(), int32s([20000000])),
        throwsA(isA<FormatException>().having((e) => e.offset, 'offset', 0)),
      );
    });
  });

  final structType = NodeId.fromString(1, 'ST_Guard');
  final structNode = NodeId.fromString(1, 'guard.struct');
  // Values the member is served with: a needle the proxy finds in the
  // response, with the member's length (3) in front of it.
  const served = [0x11111111, 0x22222222, 0x33333333];
  final needle = int32s([3, ...served]);
  final hostile = int32s([0x7FFFFFFF, ...served]);

  DynamicValue structValue() {
    final s = DynamicValue(name: 'ST_Guard', typeId: structType);
    s['values'] = DynamicValue.fromList([
      for (final n in served) DynamicValue(value: n, typeId: NodeId.int32),
    ], typeId: NodeId.int32);
    s['after'] = DynamicValue(value: 42, typeId: NodeId.int32);
    return s;
  }

  for (final clientType in clientTypes) {
    group('$clientType client: a struct whose array member claims 2^31-1 elements', () {
      late Server server;
      late DataValueRewritingProxy proxy;
      late ClientApi client;
      var rewrites = 0;

      setUp(() async {
        server = setupServer();
        addBasicVariables(server);
        server.addCustomType(structType, structValue());
        server.addDataTypeNode(structType, 'ST_Guard');
        server.addVariableNode(structNode, structValue(), typeId: structType);
        proxy = await DataValueRewritingProxy.start(server.port);
        rewrites = 0;
        proxy.rewriteMessage = (message) {
          if (!isReadResponse(message)) return message;
          final (rewritten, count) = replaceBytes(message, needle, hostile);
          rewrites += count;
          return rewritten;
        };
        client = await setupClientOfType(clientType, 'opc.tcp://127.0.0.1:${proxy.port}');
      });

      tearDown(() async {
        await client.delete();
        await proxy.close();
        server.shutdown();
        server.delete();
      });

      final decodeError = predicate<Object>(
        (e) => '$e'.contains('Array length 2147483647 exceeds the 16 bytes left in the buffer'),
        'the decode error naming the length and the bytes left',
      );

      for (final (name, readIt) in [
        ('read', (ClientApi c, NodeId node) async => (await c.read(node))),
        ('readValue', (ClientApi c, NodeId node) async => (await c.readValue(node)).value),
      ]) {
        test('$name fails with the decode error and the client stays usable', () async {
          await expectLater(readIt(client, structNode), throwsA(decodeError));
          expect(rewrites, greaterThan(0), reason: 'the proxy rewrote the member\'s length');

          // The same client, the same session: a sane node reads, and once
          // the server's answer is left alone the struct itself reads.
          expect((await client.read(intNodeId)).value, 1);
          proxy.rewriteMessage = null;
          final value = await readIt(client, structNode);
          expect(value['values'].asArray.map((e) => e.value).toList(), served);
          expect(value['after'].value, 42);
        }, timeout: const Timeout(Duration(seconds: 30)));
      }
    });
  }
}
