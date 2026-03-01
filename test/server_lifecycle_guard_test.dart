import 'dart:math';

import 'package:test/test.dart';
import 'package:open62541/open62541.dart';

void main() {
  group('Server lifecycle guard', () {
    late Server server;
    final port = Random().nextInt(10000) + 30000;

    setUp(() {
      server = Server(port: port, logLevel: LogLevel.UA_LOGLEVEL_ERROR);
      server.start();
    });

    tearDown(() {
      // Server may already be shut down / deleted by the test itself.
      // The guard should make these safe to call redundantly.
      try {
        server.shutdown();
      } catch (_) {}
      try {
        server.delete();
      } catch (_) {}
    });

    test('isRunning reflects server state', () {
      expect(server.isRunning, true);
      server.shutdown();
      expect(server.isRunning, false);
      server.delete();
      expect(server.isRunning, false);
    });

    test('methods throw StateError after shutdown + delete', () {
      server.shutdown();
      server.delete();

      expect(() => server.addVariableNode(
        NodeId.fromString(1, 'test.var'),
        DynamicValue(value: 1, typeId: NodeId.int32, name: 'test.var'),
      ), throwsStateError);

      expect(() => server.addObjectNode(
        NodeId.fromString(1, 'test.obj'),
        'TestObject',
      ), throwsStateError);

      expect(() => server.deleteNode(NodeId.fromString(1, 'test.var')),
          throwsStateError);

      expect(() => server.writeDescription(
        NodeId.fromString(1, 'test.var'),
        LocalizedText('desc', ''),
      ), throwsStateError);

      expect(() => server.writeDisplayName(
        NodeId.fromString(1, 'test.var'),
        LocalizedText('name', ''),
      ), throwsStateError);

      expect(server.read(NodeId.fromString(1, 'test.var')),
          throwsStateError);

      expect(server.write(
        NodeId.fromString(1, 'test.var'),
        DynamicValue(value: 42, typeId: NodeId.int32),
      ), throwsStateError);

      expect(() => server.browse(NodeId.fromString(1, 'test.var')),
          throwsStateError);

      expect(() => server.browseTree(NodeId.fromString(1, 'test.var')),
          throwsStateError);

      expect(() => server.addCustomType(
        NodeId.fromString(1, 'test.type'),
        DynamicValue(typeId: NodeId.structure, name: 'TestType', value: {
          'field1': DynamicValue(value: 0, typeId: NodeId.int32),
        }),
      ), throwsStateError);

      expect(() => server.monitorVariable(NodeId.fromString(1, 'test.var')),
          throwsStateError);

      expect(() => server.addMethodNode(
        NodeId.fromString(1, 'test.method'),
        'TestMethod',
        callback: (inputs) => [],
      ), throwsStateError);

      expect(() => server.setMethodAccess(
        NodeId.fromString(1, 'test.method'),
        allowedUsers: {'user1'},
      ), throwsStateError);

      expect(() => server.start(), throwsStateError);

      expect(server.runIterate(), false);
    });

    test('methods throw StateError after shutdown (before delete)', () {
      server.shutdown();

      // Server is stopped but not deleted — methods should still throw
      expect(() => server.addVariableNode(
        NodeId.fromString(1, 'test.var'),
        DynamicValue(value: 1, typeId: NodeId.int32, name: 'test.var'),
      ), throwsStateError);

      expect(() => server.browse(
        NodeId.fromNumeric(0, 85), // Objects folder
      ), throwsStateError);

      expect(server.read(NodeId.fromString(1, 'test.var')),
          throwsStateError);
    });

    test('shutdown and delete are idempotent after delete', () {
      server.shutdown();
      server.delete();

      // Calling shutdown/delete again should not crash
      expect(() => server.shutdown(), throwsStateError);
      expect(() => server.delete(), throwsStateError);
    });
  });
}
