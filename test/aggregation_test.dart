import 'dart:async';
import 'dart:math';

import 'package:test/test.dart';
import 'package:open62541/open62541.dart';
import 'common.dart';

void main() {
  group('Aggregation gateway', () {
    Server? serverA;
    Server? serverB;
    Client? clientA;
    Client? clientB;
    final portA = Random().nextInt(10000) + 14840;
    final portB = portA + 1;

    setUp(() async {
      serverA = setupServer(portA);
      serverB = setupServer(portB);
      clientA = await setupClient(portA);
      clientB = await setupClient(portB);
    });

    tearDown(() async {
      await clientA?.delete();
      await clientB?.delete();
      stopServerLoop();
      await Future.delayed(Duration(milliseconds: 20));
      serverA?.shutdown();
      serverA?.delete();
      serverB?.shutdown();
      serverB?.delete();
    });

    test('client reads from server A, server B exposes same data', () async {
      // 1. Server A has variables with attributes
      serverA!.addVariableNode(boolNodeId, DynamicValue(value: true, typeId: NodeId.boolean, name: "the.bool"));
      await serverA!.writeAttribute(
        boolNodeId,
        AttributeId.UA_ATTRIBUTEID_DESCRIPTION,
        LocalizedText("A boolean variable", ""),
      );

      serverA!.addVariableNode(intNodeId, DynamicValue(value: 42, typeId: NodeId.int32, name: "the.int"));

      // 2. Client A reads values + attributes from Server A
      final readResult = await clientA!.readAttribute({
        boolNodeId: [
          AttributeId.UA_ATTRIBUTEID_VALUE,
          AttributeId.UA_ATTRIBUTEID_DISPLAYNAME,
          AttributeId.UA_ATTRIBUTEID_DESCRIPTION,
          AttributeId.UA_ATTRIBUTEID_DATATYPE,
        ],
        intNodeId: [
          AttributeId.UA_ATTRIBUTEID_VALUE,
          AttributeId.UA_ATTRIBUTEID_DISPLAYNAME,
          AttributeId.UA_ATTRIBUTEID_DATATYPE,
        ],
      });

      // 3. Server B creates matching nodes with the read data
      final boolData = readResult[boolNodeId]!;
      serverB!.addVariableNode(
        boolNodeId,
        DynamicValue(value: boolData.value, typeId: boolData.typeId, name: "the.bool"),
      );
      await serverB!.writeAttribute(boolNodeId, AttributeId.UA_ATTRIBUTEID_DESCRIPTION, boolData.description!);

      final intData = readResult[intNodeId]!;
      serverB!.addVariableNode(intNodeId, DynamicValue(value: intData.value, typeId: intData.typeId, name: "the.int"));

      // 4. Client B reads from Server B and verifies it matches
      final boolFromB = await clientB!.read(boolNodeId);
      expect(boolFromB.value, true, reason: 'Bool value should match');

      final intFromB = await clientB!.read(intNodeId);
      expect(intFromB.value, 42, reason: 'Int value should match');

      // Read attributes from Server B and verify
      final attrFromB = await clientB!.readAttribute({
        boolNodeId: [AttributeId.UA_ATTRIBUTEID_DESCRIPTION],
      });
      expect(attrFromB[boolNodeId]!.description!.value, "A boolean variable", reason: 'Description should match');
    });

    test('client monitors server A, pushes changes to server B', () async {
      // 1. Server A and B have the same variable
      serverA!.addVariableNode(boolNodeId, DynamicValue(value: false, typeId: NodeId.boolean, name: "the.bool"));
      serverB!.addVariableNode(boolNodeId, DynamicValue(value: false, typeId: NodeId.boolean, name: "the.bool"));

      // 2. Client A monitors Server A
      final sub = await clientA!.subscriptionCreate(requestedPublishingInterval: Duration(milliseconds: 10));

      final valuesReceived = <bool>[];
      final completer = Completer<void>();
      final stream = clientA!.monitor(boolNodeId, sub, samplingInterval: Duration(milliseconds: 10));

      final subscription = stream.listen((data) {
        valuesReceived.add(data.value as bool);
        // 3. On data change, write to Server B directly
        serverB!.write(boolNodeId, DynamicValue(value: data.value, typeId: NodeId.boolean));
        if (valuesReceived.length >= 3) {
          if (!completer.isCompleted) completer.complete();
        }
      });

      // Wait for initial value
      await Future.delayed(Duration(milliseconds: 200));

      // 4. Write changes to Server A
      await clientA!.write(boolNodeId, DynamicValue(value: true, typeId: NodeId.boolean));
      await Future.delayed(Duration(milliseconds: 200));
      await clientA!.write(boolNodeId, DynamicValue(value: false, typeId: NodeId.boolean));

      // Wait for all values to propagate
      await completer.future.timeout(Duration(seconds: 5));
      await subscription.cancel();

      // 5. Client B reads from Server B, sees updated data
      final result = await clientB!.read(boolNodeId);
      expect(result.value, false, reason: 'Server B should have the latest value from Server A');
    });

    test('aggregation with all basic types (bool, int, double, string)', () async {
      // Server A has all types
      serverA!.addVariableNode(boolNodeId, DynamicValue(value: true, typeId: NodeId.boolean, name: "the.bool"));
      serverA!.addVariableNode(intNodeId, DynamicValue(value: 42, typeId: NodeId.int32, name: "the.int"));
      serverA!.addVariableNode(doubleNodeId, DynamicValue(value: 3.14, typeId: NodeId.double, name: "the.double"));
      serverA!.addVariableNode(
        stringNodeId,
        DynamicValue(value: "Hello World!", typeId: NodeId.uastring, name: "the.string"),
      );

      // Client A reads all values and types from Server A
      final readResult = await clientA!.readAttribute({
        boolNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE, AttributeId.UA_ATTRIBUTEID_DATATYPE],
        intNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE, AttributeId.UA_ATTRIBUTEID_DATATYPE],
        doubleNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE, AttributeId.UA_ATTRIBUTEID_DATATYPE],
        stringNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE, AttributeId.UA_ATTRIBUTEID_DATATYPE],
      });

      // Replicate to Server B
      for (final entry in readResult.entries) {
        final data = entry.value;
        serverB!.addVariableNode(
          entry.key,
          DynamicValue(value: data.value, typeId: data.typeId, name: entry.key.toString()),
        );
      }

      // Client B reads from Server B — all values should match
      final boolFromB = await clientB!.read(boolNodeId);
      expect(boolFromB.value, true, reason: 'Bool value should match');

      final intFromB = await clientB!.read(intNodeId);
      expect(intFromB.value, 42, reason: 'Int value should match');

      final doubleFromB = await clientB!.read(doubleNodeId);
      expect(doubleFromB.value, closeTo(3.14, 0.001), reason: 'Double value should match');

      final stringFromB = await clientB!.read(stringNodeId);
      expect(stringFromB.value, "Hello World!", reason: 'String value should match');
    });

    test('browse replication from server A to server B', () async {
      // Server A has variables
      serverA!.addVariableNode(boolNodeId, DynamicValue(value: true, typeId: NodeId.boolean, name: "the.bool"));
      serverA!.addVariableNode(intNodeId, DynamicValue(value: 1, typeId: NodeId.int32, name: "the.int"));

      // Client A browses Server A's Objects folder
      final browseResultA = await clientA!.browse(NodeId.objectsFolder);
      expect(browseResultA, isNotEmpty);

      // Server B browses its own Objects folder for comparison
      final serverBBrowseBefore = serverB!.browse(NodeId.objectsFolder);

      // Replicate: for each variable found in Server A, create it on Server B
      for (final item in browseResultA) {
        if (item.nodeClass == NodeClass.UA_NODECLASS_VARIABLE) {
          final data = await clientA!.readAttribute({
            item.nodeId: [AttributeId.UA_ATTRIBUTEID_VALUE, AttributeId.UA_ATTRIBUTEID_DATATYPE],
          });
          final dv = data[item.nodeId];
          if (dv != null && dv.typeId != null) {
            try {
              serverB!.addVariableNode(
                item.nodeId,
                DynamicValue(value: dv.value, typeId: dv.typeId, name: item.displayName),
              );
            } catch (_) {
              // Node may already exist or type not supported — skip
            }
          }
        }
      }

      // Server B should now have more items in Objects folder
      final serverBBrowseAfter = serverB!.browse(NodeId.objectsFolder);
      expect(
        serverBBrowseAfter.length,
        greaterThan(serverBBrowseBefore.length),
        reason: 'Server B should have new nodes after replication',
      );

      // The replicated nodes should be readable from Client B
      final boolFromB = await clientB!.read(boolNodeId);
      expect(boolFromB.value, true);
    });
  });
}
