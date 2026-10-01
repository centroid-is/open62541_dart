// Regression test for a double free in Server.addVariableTypeNode.
//
// Symptom
//   Every call killed the process: glibc aborts with
//   "free(): double free detected in tcache 2", AddressSanitizer reports
//   "attempting double-free".
//
// Root cause
//   lib/src/server.dart addVariableTypeNode() shallow-copies the value's
//   variant into the UA_VariableTypeAttributes it passes to open62541, and then
//   deleted both: UA_Variant_delete freed the variant's payload, and
//   UA_VariableTypeAttributes_delete, whose copy still pointed at it, freed it a
//   second time.
//
// What this test asserts
//   The process is still alive after the call and the server still works. A
//   double free takes the whole test runner down, so on the unpatched server
//   this file does not fail an expectation: the run dies in it.
//
//   Whether the type node is added is not asserted. Today the add is refused
//   with BadTypeMismatch (the node's DataType attribute is set to the type
//   node's own NodeId), and the double free happened on that path as well as on
//   success.

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';

void main() {
  late Server server;

  setUp(() => server = Server(logLevel: LogLevel.UA_LOGLEVEL_FATAL));
  tearDown(() => server.delete());

  /// Adds a variable type node with [value], whatever the outcome.
  void addVariableTypeNode(String name, DynamicValue value) {
    try {
      server.addVariableTypeNode(value, NodeId.fromString(1, name), name);
    } catch (_) {
      // Refused, see above.
    }
  }

  void expectServerWorks() {
    final nodeId = NodeId.fromString(1, 'after');
    server.addVariableNode(nodeId, DynamicValue(value: 42, typeId: NodeId.int32, name: 'after'));
    expect(server.read(nodeId).asInt, 42, reason: 'the server must still work after addVariableTypeNode');
  }

  test('addVariableTypeNode with a scalar value: no crash', () {
    addVariableTypeNode('ScalarType', DynamicValue(value: 42, typeId: NodeId.int32));
    expectServerWorks();
  });

  test('addVariableTypeNode with a string value: no crash', () {
    addVariableTypeNode('StringType', DynamicValue(value: 'a string value', typeId: NodeId.uastring));
    expectServerWorks();
  });

  test('addVariableTypeNode with an array value: no crash', () {
    final array = DynamicValue(typeId: NodeId.int32);
    for (var i = 0; i < 16; i++) {
      array[i] = DynamicValue(value: i, typeId: NodeId.int32);
    }
    addVariableTypeNode('ArrayType', array);
    expectServerWorks();
  });
}
