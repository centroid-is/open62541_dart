import 'dart:math';

import 'package:test/test.dart';
import 'package:open62541/open62541.dart';

void main() {
  group('Server custom type delete/re-add', () {
    late Server server;
    final port = Random().nextInt(10000) + 30000;

    final customTypeId = NodeId.fromString(1, 'MyStruct');
    final varNodeId = NodeId.fromString(1, 'my.struct.var');

    DynamicValue makeCustomType() => DynamicValue(
          typeId: NodeId.structure,
          name: 'MyStruct',
          value: {
            'field1': DynamicValue(value: 0, typeId: NodeId.int32),
            'field2': DynamicValue(value: 0.0, typeId: NodeId.double),
          },
        );

    DynamicValue makeValue(int i) => DynamicValue(
          value: {
            'field1': DynamicValue(value: i, typeId: NodeId.int32),
            'field2': DynamicValue(value: i * 1.0, typeId: NodeId.double),
          },
          typeId: customTypeId,
          name: 'my.struct.var',
        );

    setUp(() {
      server = Server(port: port, logLevel: LogLevel.UA_LOGLEVEL_ERROR);
      server.start();
    });

    tearDown(() {
      try {
        server.shutdown();
      } catch (_) {}
      try {
        server.delete();
      } catch (_) {}
    });

    test('addCustomType + addVariableNode + deleteNode + re-add does not crash',
        () {
      server.addCustomType(customTypeId, makeCustomType());
      server.addVariableNode(varNodeId, makeValue(42), typeId: customTypeId);

      server.deleteNode(varNodeId);

      server.addCustomType(customTypeId, makeCustomType());
      server.addVariableNode(
        NodeId.fromString(1, 'my.struct.var2'),
        makeValue(99),
        typeId: customTypeId,
      );
    });

    test('addCustomType with unregistered member typeId throws instead of SEGFAULT', () {
      // Reproduces the production SEGFAULT at address 0x50:
      // _findDataType returns nullptr for a member type, and
      // memberType.ref.memSize dereferences null + 0x50 offset.
      final outerTypeId = NodeId.fromString(1, 'OuterStruct');

      expect(
        () => server.addCustomType(
          outerTypeId,
          DynamicValue(
            typeId: NodeId.structure,
            name: 'OuterStruct',
            value: {
              'field1': DynamicValue(value: 0, typeId: NodeId.int32),
              // This member uses a typeId that hasn't been registered
              'field2': DynamicValue(
                  value: 0, typeId: NodeId.fromString(1, 'UnknownType')),
            },
          ),
        ),
        throwsStateError,
      );
    });
  });
}
