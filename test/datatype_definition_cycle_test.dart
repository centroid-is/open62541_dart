// Client.buildSchema fetches the DataTypeDefinition of a structured type and
// recurses into every field whose DataType is itself structured. The
// definitions are the server's word, and one whose field names the type
// being defined (A with a field of type A, or A -> B -> A) used to be
// followed forever, one readAttribute round trip per level: a `read`,
// `readValue`, `call` or monitor of a value of that type never completed.
//
// Now the chain of types being resolved is carried down the recursion: a
// type met again is refused with DataTypeDefinitionCycle naming the cycle,
// and more than DataTypeDefinitionTooDeep.limit (100, open62541's own
// decoder bound) nested levels with DataTypeDefinitionTooDeep. The read
// fails with the error and the client stays usable.
//
// Fixtures
//   A Dart Server cannot register a self-referential type (a DynamicValue
//   tree is finite), so DataValueRewritingProxy sits in front of one and
//   rewrites the DataTypeDefinition ReadResponse: a field's DataType NodeId
//   (a string id of the same length as the cycle target's) is overwritten
//   with the target's. `CycA {inner: CycB, n}`, `CycB {back: CycC, flag}`,
//   `CycC {flag}`: CycB -> CycA in A's definition is the direct cycle, CycC
//   -> CycA in B's definition the indirect one. The depth cap needs no
//   rewrite: a chain of 102 nested struct types is registered as it is.
//
// Red/green
//   Without the guards the cycle reads never complete (the tests time out)
//   and the deep read decodes.

import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart';
import 'data_value_rewriting_proxy.dart';

/// The four-byte-identifier wire form of `ns=1;s=<name>`: encoding 0x03,
/// namespace 1, Int32 length, the characters.
List<int> stringNodeIdBytes(String name) => [
  0x03,
  0x01,
  0x00,
  ...Uint8List(4)..buffer.asByteData().setInt32(0, name.length, Endian.little),
  ...name.codeUnits,
];

void main() {
  final typeA = NodeId.fromString(1, 'CycA');
  final typeB = NodeId.fromString(1, 'CycB');
  final typeC = NodeId.fromString(1, 'CycC');
  final nodeA = NodeId.fromString(1, 'cyc.a');

  DynamicValue valueC() {
    final c = DynamicValue(name: 'CycC', typeId: typeC);
    c['flag'] = DynamicValue(value: true, typeId: NodeId.boolean);
    return c;
  }

  DynamicValue valueB() {
    final b = DynamicValue(name: 'CycB', typeId: typeB);
    b['back'] = valueC();
    b['flag'] = DynamicValue(value: false, typeId: NodeId.boolean);
    return b;
  }

  DynamicValue valueA() {
    final a = DynamicValue(name: 'CycA', typeId: typeA);
    a['inner'] = valueB();
    a['n'] = DynamicValue(value: 7, typeId: NodeId.int32);
    return a;
  }

  // Deep: D0 {next: D1}, ..., D101 {leaf: Boolean}: 102 nested struct types,
  // one past the cap when D0 is resolved.
  const deepLevels = DataTypeDefinitionTooDeep.limit + 2;
  NodeId deepType(int level) => NodeId.fromString(1, 'Deep$level');
  final deepNode = NodeId.fromString(1, 'deep.d0');
  DynamicValue deepValue(int level) {
    final v = DynamicValue(name: 'Deep$level', typeId: deepType(level));
    if (level == deepLevels - 1) {
      v['leaf'] = DynamicValue(value: true, typeId: NodeId.boolean);
    } else {
      v['next'] = deepValue(level + 1);
    }
    return v;
  }

  for (final clientType in clientTypes) {
    group('$clientType client: a DataTypeDefinition that refers back to a type being resolved', () {
      late Server server;
      late DataValueRewritingProxy proxy;
      late ClientApi client;
      var rewrites = 0;

      /// Rewrites the DataType NodeId [from] to [to] in every ReadResponse.
      void rewriteDataType(String from, String to) {
        proxy.rewriteMessage = (message) {
          if (!isReadResponse(message)) return message;
          final (rewritten, count) = replaceBytes(message, stringNodeIdBytes(from), stringNodeIdBytes(to));
          rewrites += count;
          return rewritten;
        };
      }

      setUp(() async {
        server = setupServer();
        addBasicVariables(server);
        server.addCustomType(typeA, valueA());
        server.addDataTypeNode(typeA, 'CycA');
        server.addVariableNode(nodeA, valueA(), typeId: typeA);
        server.addCustomType(deepType(0), deepValue(0));
        server.addDataTypeNode(deepType(0), 'Deep0');
        server.addVariableNode(deepNode, deepValue(0), typeId: deepType(0));
        proxy = await DataValueRewritingProxy.start(server.port);
        rewrites = 0;
        client = await setupClientOfType(clientType, 'opc.tcp://127.0.0.1:${proxy.port}');
      });

      tearDown(() async {
        await client.delete();
        await proxy.close();
        server.shutdown();
        server.delete();
      });

      Future<void> expectCycle(List<NodeId> cycle) async {
        final watch = Stopwatch()..start();
        await expectLater(
          client.read(nodeA),
          throwsA(
            predicate<Object>(
              (e) => '$e'.contains('DataTypeDefinitionCycle') && '$e'.contains(cycle.join(' -> ')),
              'DataTypeDefinitionCycle naming ${cycle.join(' -> ')}',
            ),
          ),
        );
        expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
        expect(rewrites, greaterThan(0), reason: 'the proxy rewrote a field\'s DataType');

        // The same client: a sane node reads, and with the definitions left
        // alone the struct itself decodes (nothing of the refused schema was
        // cached).
        expect((await client.read(intNodeId)).value, 1);
        proxy.rewriteMessage = null;
        final value = await client.read(nodeA);
        expect(value['inner']['back']['flag'].value, isTrue);
        expect(value['n'].value, 7);
      }

      test('a field of the type itself (A -> A): read fails with the cycle, the client stays usable', () async {
        rewriteDataType('CycB', 'CycA');
        await expectCycle([typeA, typeA]);
      }, timeout: const Timeout(Duration(seconds: 30)));

      test('a cycle through another type (A -> B -> A): read fails with the cycle', () async {
        rewriteDataType('CycC', 'CycA');
        await expectCycle([typeA, typeB, typeA]);
      }, timeout: const Timeout(Duration(seconds: 30)));

      test('more than ${DataTypeDefinitionTooDeep.limit} nested levels: read fails with the depth error', () async {
        await expectLater(
          client.read(deepNode),
          throwsA(
            predicate<Object>(
              (e) => '$e'.contains('DataTypeDefinitionTooDeep') && '$e'.contains('${deepType(0)}'),
              'DataTypeDefinitionTooDeep naming ${deepType(0)}',
            ),
          ),
        );
        expect((await client.read(intNodeId)).value, 1);
      }, timeout: const Timeout(Duration(seconds: 60)));
    });
  }
}
