import 'dart:async';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart';

/// Regression tests for reading custom structs whose members include
/// pointer-bearing types (UA_String).
///
/// Before the fix, `Server.addVariableNode` stored the binary-encoded body of a
/// struct value while labelling the variant as the native custom type. That only
/// works when every member is a fixed-size, pointer-free primitive. For a String
/// member (native `{size_t; UA_Byte*}` vs wire `[int32][utf8]`) open62541 walked
/// the members and dereferenced the encoded bytes as a pointer, corrupting the
/// heap and wedging/aborting the process - so the client read never returned.
void main() {
  group('Struct with String members (client read)', () {
    late int port;
    Server? server;
    Client? client;

    setUp(() async {
      port = await freeTcpPort();
      server = setupServer(port);
      client = await setupClient(port);
    });

    tearDown(() async {
      await client?.delete();
      server?.shutdown();
      server?.delete();
    });

    test('write then read a struct with 3 String members', () async {
      final structureVariableNodeId = NodeId.fromString(1, "structureVariable");
      final myStructureTypeId = NodeId.fromString(1, "myStructureType");
      DynamicValue structureValue = DynamicValue(name: "My Structure Variable", typeId: myStructureTypeId);
      structureValue["a"] = DynamicValue(value: "abab", typeId: NodeId.uastring);
      structureValue["b"] = DynamicValue(value: "abba", typeId: NodeId.uastring);
      structureValue["c"] = DynamicValue(value: "baab", typeId: NodeId.uastring);

      server!.addCustomType(myStructureTypeId, structureValue);
      server!.addDataTypeNode(
        myStructureTypeId,
        "myStructureType",
        displayName: LocalizedText("My Structure Type", "en-US"),
      );
      server!.addVariableNode(
        structureVariableNodeId,
        structureValue,
        accessLevel: AccessLevelMask(read: true, write: true),
        typeId: myStructureTypeId,
      );

      // Guard with a bounded timeout: the unpatched code wedges here.
      final value = await client!
          .read(structureVariableNodeId)
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw TimeoutException('client.read of all-string struct did not return'),
          );
      expect(value.isObject, isTrue);
      expect(value.typeId, myStructureTypeId);
      expect(value.asObject.length, 3);
      expect(value["a"].value, "abab");
      expect(value["b"].value, "abba");
      expect(value["c"].value, "baab");

      value["a"] = "a value";
      value["b"] = "b value";
      value["c"] = "c value";

      await client!.write(structureVariableNodeId, value);
      final value2 = await client!.read(structureVariableNodeId).timeout(const Duration(seconds: 10));

      expect(value2["a"].value, "a value");
      expect(value2["b"].value, "b value");
      expect(value2["c"].value, "c value");
    });

    test('read a struct mixing a String member with primitives returns in bounded time', () async {
      final structureVariableNodeId = NodeId.fromString(1, "mixedStructureVariable");
      final myStructureTypeId = NodeId.fromString(1, "myMixedStructureType");
      DynamicValue structureValue = DynamicValue(name: "My Mixed Structure Variable", typeId: myStructureTypeId);
      structureValue["count"] = DynamicValue(value: 7, typeId: NodeId.int32);
      structureValue["label"] = DynamicValue(value: "hello", typeId: NodeId.uastring);
      structureValue["flag"] = DynamicValue(value: true, typeId: NodeId.boolean);

      server!.addCustomType(myStructureTypeId, structureValue);
      server!.addDataTypeNode(
        myStructureTypeId,
        "myMixedStructureType",
        displayName: LocalizedText("My Mixed Structure Type", "en-US"),
      );
      server!.addVariableNode(
        structureVariableNodeId,
        structureValue,
        accessLevel: AccessLevelMask(read: true, write: true),
        typeId: myStructureTypeId,
      );

      // Must not time out (previously an unbounded wedge). A thrown error would
      // also satisfy "bounded" for an HMI, but here it must succeed with values.
      final value = await client!
          .read(structureVariableNodeId)
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw TimeoutException('client.read of mixed struct did not return'),
          );
      expect(value.isObject, isTrue);
      expect(value["count"].value, 7);
      expect(value["label"].value, "hello");
      expect(value["flag"].value, true);
    });
  });
}
