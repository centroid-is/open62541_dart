// `Server.addVariableNode` defaults to a read-only node: a client write is
// refused unless the server asked for a writable node with an explicit
// `AccessLevelMask`. The server's own `write` bypasses the access level
// (open62541 grants the local admin session every right), so a read-only
// node is still the server's to update.

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'common.dart';

void main() {
  final defaultNodeId = NodeId.fromString(1, 'access.default');
  final writableNodeId = NodeId.fromString(1, 'access.writable');

  for (final clientType in clientTypes) {
    group('[$clientType] addVariableNode access level', () {
      late Server server;
      late ClientApi client;

      setUp(() async {
        server = setupServer();
        server.addVariableNode(defaultNodeId, DynamicValue(value: 1, typeId: NodeId.int32, name: 'access.default'));
        server.addVariableNode(
          writableNodeId,
          DynamicValue(value: 1, typeId: NodeId.int32, name: 'access.writable'),
          accessLevel: const AccessLevelMask(read: true, write: true),
        );
        client = await setupClientOfType(clientType, 'opc.tcp://127.0.0.1:${server.port}');
      });

      tearDown(() async {
        await client.delete();
        server.shutdown();
        server.delete();
      });

      test('a node added with the default refuses a client write with Bad_UserAccessDenied', () async {
        expect((await client.read(defaultNodeId)).asInt, 1, reason: 'anti-vacuity: the node reads');

        await expectLater(
          client.write(defaultNodeId, DynamicValue(value: 2, typeId: NodeId.int32)),
          throwsA(
            isA<UaStatusException>().having((e) => e.statusCode, 'statusCode', raw.UA_STATUSCODE_BADUSERACCESSDENIED),
          ),
        );
        expect((await client.read(defaultNodeId)).asInt, 1, reason: 'the refused write changed nothing');
      });

      test('the server itself still writes a node added with the default', () async {
        server.write(defaultNodeId, DynamicValue(value: 3, typeId: NodeId.int32));

        expect((await client.read(defaultNodeId)).asInt, 3);
      });

      test('a node added with an explicit write mask accepts a client write', () async {
        await client.write(writableNodeId, DynamicValue(value: 2, typeId: NodeId.int32));

        expect((await client.read(writableNodeId)).asInt, 2);
      });
    });
  }
}
