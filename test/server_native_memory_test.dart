import 'dart:collection';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'heap_growth.dart';

/// Regression tests for native memory a [Server] allocated and never freed.
/// Each repeats one operation that must leave the C heap as it found it, see
/// heap_growth.dart.
///
/// No server here is started: creating one and adding nodes to it needs no
/// listening socket, so nothing depends on a port.
void main() {
  test('a server leaves nothing on the C heap once deleted', () async {
    // Creating a server builds the whole namespace 0, about 100 ms: a few
    // servers per round have to do. One leaked UA_ServerConfig is 1184 bytes;
    // the heap still settles by a hundred or two per server this early on.
    await expectNoHeapGrowth(
      () => Server(logLevel: LogLevel.UA_LOGLEVEL_FATAL).delete(),
      warmUp: 6,
      iterations: 4,
      rounds: 5,
      maxGrowth: 600,
      attempts: 3,
    );
  });

  group('nodes:', () {
    late Server server;

    setUp(() => server = Server(logLevel: LogLevel.UA_LOGLEVEL_FATAL));
    tearDown(() => server.delete());

    final nodeId = NodeId.fromString(1, 'leak.test.node');
    const browseName = 'LeakTestNode';

    Future<void> expectNoGrowth(void Function() operation) =>
        expectNoHeapGrowth(operation, warmUp: 2000, iterations: 1000, rounds: 9);

    /// Runs [add], which must throw, and checks the failure leaves nothing.
    Future<void> expectRefusedAddLeavesNothing(void Function() add, Matcher error) {
      expect(add, error);
      return expectNoGrowth(() {
        try {
          add();
        } catch (_) {
          // Expected, checked above.
        }
      });
    }

    // What adds one node of each kind, with [nodeId] as its NodeId.
    final kinds = <String, void Function()>{
      'a variable node': () =>
          server.addVariableNode(nodeId, DynamicValue(value: 1, typeId: NodeId.int32, name: browseName)),
      'a data-source variable node': () => server.addDataSourceVariableNode(
        nodeId,
        onRead: () => DynamicValue(value: 1, typeId: NodeId.int32),
        browseName: browseName,
        typeId: NodeId.int32,
      ),
      'a method node': () => server.addMethodNode(
        nodeId,
        browseName: browseName,
        inputArguments: [
          Argument(
            name: 'in',
            dataType: NodeId.int32,
            valueRank: 1,
            arrayDimensions: [3],
            description: LocalizedText('An input', 'en-US'),
          ),
        ],
        outputArguments: [Argument(name: 'out', dataType: NodeId.fromString(1, 'leak.test.type'))],
        callback: (inputs, session) async => inputs,
      ),
    };

    for (final MapEntry(key: kind, value: add) in kinds.entries) {
      test('adding and deleting $kind leaves nothing on the C heap', () async {
        await expectNoGrowth(() {
          add();
          server.deleteNode(nodeId);
        });
      });

      test('adding $kind that already exists leaves nothing on the C heap', () async {
        add();
        await expectRefusedAddLeavesNothing(add, throwsA(contains('BadNodeIdExists')));
      });
    }

    // Refused today whatever the value (BadTypeMismatch, see
    // variable_type_node_test.dart), so only the failing path can be measured.
    test('a refused variable type node leaves nothing on the C heap', () async {
      await expectRefusedAddLeavesNothing(
        () => server.addVariableTypeNode(
          DynamicValue(value: 1, typeId: NodeId.int32),
          nodeId,
          browseName,
          displayName: LocalizedText('Leak test node', 'en-US'),
        ),
        throwsA(contains('BadTypeMismatch')),
      );
    });

    test('a variable node without a name leaves nothing on the C heap', () async {
      await expectRefusedAddLeavesNothing(
        () => server.addVariableNode(nodeId, DynamicValue(value: 1, typeId: NodeId.int32)),
        throwsA(contains('name must be provided')),
      );
    });

    test('a method node whose arguments cannot be marshalled leaves nothing on the C heap', () async {
      await expectRefusedAddLeavesNothing(
        () => server.addMethodNode(
          nodeId,
          browseName: browseName,
          inputArguments: [Argument(name: 'in', dataType: NodeId.fromString(1, 'leak.test.type'))],
          outputArguments: [Argument(name: 'out', dataType: NodeId.int32, arrayDimensions: _UnreadableList())],
          callback: (inputs, session) async => inputs,
        ),
        throwsStateError,
      );
    });
  });
}

/// A list whose elements cannot be read, to make marshalling it fail.
class _UnreadableList extends ListBase<int> {
  @override
  int length = 1;

  @override
  int operator [](int index) => throw StateError('unreadable');

  @override
  void operator []=(int index, int value) {}
}
