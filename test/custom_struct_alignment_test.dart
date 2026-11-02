// A custom structure registered with addCustomType is laid out in native
// memory the way a C compiler lays out the equivalent struct: a member that
// follows a narrower one starts at the next multiple of its alignment. A
// packed layout made open62541 read and write a UA_String, an Int64 array or a
// Double at an odd address (UBSan: misaligned load/store; SIGBUS on strict
// alignment CPUs), and an optional member was not the pointer open62541
// expects. Each schema below puts a wide member after a narrow one; a client
// write is decoded by open62541 into the native struct, and both the client
// read (open62541 encodes it again) and the server-side read (the Dart walk
// of the native struct) must give the written value back.

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart';

DynamicValue _struct(String name, Map<String, DynamicValue> fields) {
  final s = DynamicValue(name: name, typeId: NodeId.fromString(1, name));
  fields.forEach((key, field) => s[key] = field);
  return s;
}

DynamicValue _optional(DynamicValue field) => field..isOptional = true;

final _cases = <String, DynamicValue Function(bool)>{
  'ST_ByteString': (b) => _struct('ST_ByteString', {
    'A': DynamicValue(value: b ? 0xAB : 1, typeId: NodeId.byte),
    'B': DynamicValue(value: b ? 'after a byte' : 'x', typeId: NodeId.uastring),
  }),
  'ST_BoolInt64Array': (b) => _struct('ST_BoolInt64Array', {
    'A': DynamicValue(value: b, typeId: NodeId.boolean),
    'B': DynamicValue.fromList([
      for (final n in b ? [-1, 1 << 40, 3] : [0]) DynamicValue(value: n, typeId: NodeId.int64),
    ], typeId: NodeId.int64),
  }),
  'ST_StringByteDouble': (b) => _struct('ST_StringByteDouble', {
    'A': DynamicValue(value: b ? 'lead' : '', typeId: NodeId.uastring),
    'B': DynamicValue(value: b ? 0x7F : 0, typeId: NodeId.byte),
    'C': DynamicValue(value: b ? 2.5 : 0.0, typeId: NodeId.double),
  }),
  'ST_ByteOptInt16Byte': (b) => _struct('ST_ByteOptInt16Byte', {
    'A': DynamicValue(value: b ? 9 : 0, typeId: NodeId.byte),
    'B': _optional(DynamicValue(value: b ? -1234 : 0, typeId: NodeId.int16)),
    'C': DynamicValue(value: b ? 0xEE : 0, typeId: NodeId.byte),
  }),
  'ST_ByteNested': (b) => _struct('ST_ByteNested', {
    'A': DynamicValue(value: b ? 5 : 0, typeId: NodeId.byte),
    'B': _struct('ST_ByteNested_Inner', {
      'X': DynamicValue(value: b ? -0.125 : 0.0, typeId: NodeId.double),
      'Y': DynamicValue(value: b ? 'inner' : '', typeId: NodeId.uastring),
    }),
  }),
};

void _expectSame(DynamicValue actual, DynamicValue expected, String path) {
  if (expected.isObject) {
    expect(actual.asObject.keys, expected.asObject.keys, reason: path);
    for (final key in expected.asObject.keys) {
      _expectSame(actual[key], expected[key], '$path.$key');
    }
  } else if (expected.isArray) {
    expect(actual.asArray.length, expected.asArray.length, reason: path);
    for (var i = 0; i < expected.asArray.length; i++) {
      _expectSame(actual[i], expected[i], '$path[$i]');
    }
  } else {
    expect(actual.value, expected.value, reason: path);
  }
}

void main() {
  for (final clientType in clientTypes) {
    group('$clientType client: custom struct with C alignment', () {
      late Server server;
      late ClientApi client;

      setUp(() async {
        server = setupServer();
        for (final MapEntry(key: name, value: build) in _cases.entries) {
          final typeId = NodeId.fromString(1, name);
          server.addCustomType(typeId, build(false));
          server.addDataTypeNode(typeId, name);
          server.addVariableNode(
            NodeId.fromString(1, 'align.$name'),
            build(false),
            typeId: typeId,
            accessLevel: const AccessLevelMask(read: true, write: true),
          );
        }
        client = await setupClientOfType(clientType, 'opc.tcp://127.0.0.1:${server.port}');
      });

      tearDown(() async {
        await client.delete();
        server.shutdown();
        server.delete();
      });

      for (final MapEntry(key: name, value: build) in _cases.entries) {
        test('$name round-trips through the native struct', () async {
          final nodeId = NodeId.fromString(1, 'align.$name');
          // The encoding id the server advertises, which an isolate client
          // (no access to this isolate's registry) learns by reading.
          final written = build(true)..extObjEncodingId = (await client.read(nodeId)).extObjEncodingId;
          await client.write(nodeId, written);

          _expectSame(await client.read(nodeId), written, name);
          _expectSame(server.read(nodeId), written, name);
        });
      }
    });
  }
}
