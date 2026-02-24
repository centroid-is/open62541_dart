import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart';

void main() {
  for (final clientType in ['direct', 'isolate']) {
    group('Server attributes ($clientType client)', () {
      int port = Random().nextInt(10000) + 4840;
      ClientApi? client;
      Server? server;

      setUp(() async {
        server = setupServer(port);
        client = await createClient(clientType, port);
        addBasicVariables(server!);
      });

      tearDown(() async {
        stopDirectClientLoop();
        stopServerLoop();
        await Future.delayed(Duration(milliseconds: 20));
        await client!.delete();
        server!.shutdown();
        server!.delete();
      });

      // ── readAttribute ──────────────────────────────────────────────

      group('Server readAttribute', () {
        test('reads VALUE attribute', () async {
          final result = await server!.readAttribute({
            boolNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE],
          });
          expect(result[boolNodeId], isNotNull);
          expect(result[boolNodeId]!.value, true);
        });

        test('reads DISPLAYNAME attribute', () async {
          server!.writeDescription(boolNodeId, LocalizedText("A bool", "en-US"));
          final result = await server!.readAttribute({
            boolNodeId: [AttributeId.UA_ATTRIBUTEID_DISPLAYNAME],
          });
          expect(result[boolNodeId], isNotNull);
          expect(result[boolNodeId]!.displayName, isNotNull);
        });

        test('reads DESCRIPTION attribute', () async {
          final desc = LocalizedText("A boolean variable", "en-US");
          server!.writeDescription(boolNodeId, desc);
          final result = await server!.readAttribute({
            boolNodeId: [AttributeId.UA_ATTRIBUTEID_DESCRIPTION],
          });
          expect(result[boolNodeId], isNotNull);
          expect(result[boolNodeId]!.description, isNotNull);
          expect(result[boolNodeId]!.description!.value, "A boolean variable");
        });

        test('reads DATATYPE attribute', () async {
          final result = await server!.readAttribute({
            boolNodeId: [AttributeId.UA_ATTRIBUTEID_DATATYPE],
          });
          expect(result[boolNodeId], isNotNull);
          expect(result[boolNodeId]!.typeId, NodeId.boolean);
        });

        test('reads BROWSENAME attribute', () async {
          final result = await server!.readAttribute({
            boolNodeId: [AttributeId.UA_ATTRIBUTEID_BROWSENAME],
          });
          expect(result[boolNodeId], isNotNull);
          expect(result[boolNodeId]!.name, isNotNull);
          expect(result[boolNodeId]!.name, contains("the.bool"));
        });

        test('reads NODECLASS attribute', () async {
          final result = await server!.readAttribute({
            boolNodeId: [AttributeId.UA_ATTRIBUTEID_NODECLASS],
          });
          expect(result[boolNodeId], isNotNull);
          // Variable nodes have nodeClass == 2
          expect(result[boolNodeId]!.value, NodeClass.UA_NODECLASS_VARIABLE.value);
        });

        test('reads ACCESSLEVEL attribute', () async {
          final result = await server!.readAttribute({
            boolNodeId: [AttributeId.UA_ATTRIBUTEID_ACCESSLEVEL],
          });
          expect(result[boolNodeId], isNotNull);
          // Default is read+write, so access level should be non-zero
          expect(result[boolNodeId]!.value, greaterThan(0));
        });

        test('reads multiple attributes at once', () async {
          server!.writeDescription(boolNodeId, LocalizedText("Test desc", "en-US"));
          final result = await server!.readAttribute({
            boolNodeId: [
              AttributeId.UA_ATTRIBUTEID_DESCRIPTION,
              AttributeId.UA_ATTRIBUTEID_DISPLAYNAME,
              AttributeId.UA_ATTRIBUTEID_DATATYPE,
              AttributeId.UA_ATTRIBUTEID_VALUE,
              AttributeId.UA_ATTRIBUTEID_BROWSENAME,
            ],
          });
          final dv = result[boolNodeId]!;
          expect(dv.value, true);
          expect(dv.typeId, NodeId.boolean);
          expect(dv.description, isNotNull);
          expect(dv.description!.value, "Test desc");
          expect(dv.displayName, isNotNull);
          expect(dv.name, isNotNull);
        });

        test('reads multiple nodes', () async {
          final result = await server!.readAttribute({
            boolNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE],
            intNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE],
            doubleNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE],
          });
          expect(result.length, 3);
          expect(result[boolNodeId]!.value, true);
          expect(result[intNodeId]!.value, 1);
          expect(result[doubleNodeId]!.value, 3.14);
        });

        test('client reads match server reads for all attributes', () async {
          server!.writeDescription(boolNodeId, LocalizedText("Server desc", "en-US"));

          final serverResult = await server!.readAttribute({
            boolNodeId: [
              AttributeId.UA_ATTRIBUTEID_DESCRIPTION,
              AttributeId.UA_ATTRIBUTEID_DATATYPE,
              AttributeId.UA_ATTRIBUTEID_VALUE,
            ],
          });
          final clientResult = await client!.read(boolNodeId);

          expect(serverResult[boolNodeId]!.value, clientResult.value);
          expect(serverResult[boolNodeId]!.typeId, clientResult.typeId);
          expect(serverResult[boolNodeId]!.description!.value, clientResult.description!.value);
        });
      });

      // ── writeAttribute ─────────────────────────────────────────────

      group('Server writeAttribute', () {
        test('writes VALUE attribute', () async {
          await server!.writeAttribute(
            boolNodeId,
            AttributeId.UA_ATTRIBUTEID_VALUE,
            DynamicValue(value: false, typeId: NodeId.boolean),
          );
          final result = await server!.read(boolNodeId);
          expect(result.value, false);
        });

        test('writes DISPLAYNAME and reads it back', () async {
          final newName = LocalizedText("New Display Name", "");
          await server!.writeAttribute(boolNodeId, AttributeId.UA_ATTRIBUTEID_DISPLAYNAME, newName);
          final result = await server!.readAttribute({
            boolNodeId: [AttributeId.UA_ATTRIBUTEID_DISPLAYNAME],
          });
          expect(result[boolNodeId]!.displayName!.value, "New Display Name");
        });

        test('writes DESCRIPTION and reads it back', () async {
          final newDesc = LocalizedText("Updated description", "en-US");
          await server!.writeAttribute(boolNodeId, AttributeId.UA_ATTRIBUTEID_DESCRIPTION, newDesc);
          final result = await server!.readAttribute({
            boolNodeId: [AttributeId.UA_ATTRIBUTEID_DESCRIPTION],
          });
          expect(result[boolNodeId]!.description!.value, "Updated description");
        });

        test('client sees server writeAttribute changes', () async {
          await server!.writeAttribute(
            boolNodeId,
            AttributeId.UA_ATTRIBUTEID_DESCRIPTION,
            LocalizedText("Client visible", "en-US"),
          );
          final clientResult = await client!.read(boolNodeId);
          expect(clientResult.description!.value, "Client visible");
        });
      });

      // ── readAttribute error handling ─────────────────────────────

      group('Server readAttribute error handling', () {
        test('throws on unsupported attribute', () async {
          await expectLater(
            server!.readAttribute({
              boolNodeId: [AttributeId.UA_ATTRIBUTEID_WRITEMASK],
            }),
            throwsA(contains('readAttribute not implemented')),
          );
        });

        test('readAttribute with non-existent node returns empty/null fields', () async {
          final fakeNodeId = NodeId.fromString(99, "does.not.exist");
          final result = await server!.readAttribute({
            fakeNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE],
          });
          // The result should exist but value should be null (status code was not GOOD)
          expect(result[fakeNodeId], isNotNull);
          expect(result[fakeNodeId]!.value, isNull);
        });
      });

      // ── writeAttribute error handling ───────────────────────────

      group('Server writeAttribute error handling', () {
        test('throws on unsupported attribute', () async {
          await expectLater(
            server!.writeAttribute(boolNodeId, AttributeId.UA_ATTRIBUTEID_WRITEMASK, 42),
            throwsA(contains('writeAttribute not implemented')),
          );
        });

        test('throws on wrong type for DISPLAYNAME', () async {
          await expectLater(
            server!.writeAttribute(boolNodeId, AttributeId.UA_ATTRIBUTEID_DISPLAYNAME, "not a LocalizedText"),
            throwsA(isA<TypeError>()),
          );
        });

        test('throws on wrong type for VALUE', () async {
          await expectLater(
            server!.writeAttribute(boolNodeId, AttributeId.UA_ATTRIBUTEID_VALUE, "not a DynamicValue"),
            throwsA(isA<TypeError>()),
          );
        });

        test('write to non-existent node throws', () async {
          final fakeNodeId = NodeId.fromString(99, "does.not.exist");
          await expectLater(
            server!.write(fakeNodeId, DynamicValue(value: true, typeId: NodeId.boolean)),
            throwsA(contains('Failed to write')),
          );
        });

        test('writeDescription to non-existent node throws', () {
          final fakeNodeId = NodeId.fromString(99, "does.not.exist");
          expect(
            () => server!.writeDescription(fakeNodeId, LocalizedText("test", "")),
            throwsA(contains('Failed to write Description')),
          );
        });

        test('writeDisplayName to non-existent node throws', () {
          final fakeNodeId = NodeId.fromString(99, "does.not.exist");
          expect(
            () => server!.writeDisplayName(fakeNodeId, LocalizedText("test", "")),
            throwsA(contains('Failed to write DisplayName')),
          );
        });
      });

      // ── Boundary value tests ────────────────────────────────────

      group('Server attribute boundary values', () {
        test('empty string DISPLAYNAME', () async {
          server!.writeDisplayName(boolNodeId, LocalizedText("", ""));
          final result = await server!.readAttribute({
            boolNodeId: [AttributeId.UA_ATTRIBUTEID_DISPLAYNAME],
          });
          expect(result[boolNodeId]!.displayName!.value, "");
        });

        test('unicode characters in DISPLAYNAME', () async {
          final unicodeName = "Temperatur 温度 🌡️";
          server!.writeDisplayName(boolNodeId, LocalizedText(unicodeName, ""));
          final result = await server!.readAttribute({
            boolNodeId: [AttributeId.UA_ATTRIBUTEID_DISPLAYNAME],
          });
          expect(result[boolNodeId]!.displayName!.value, unicodeName);
        });

        test('unicode characters in DESCRIPTION', () async {
          final unicodeDesc = "Описание переменной — 変数の説明";
          server!.writeDescription(boolNodeId, LocalizedText(unicodeDesc, ""));
          final result = await server!.readAttribute({
            boolNodeId: [AttributeId.UA_ATTRIBUTEID_DESCRIPTION],
          });
          expect(result[boolNodeId]!.description!.value, unicodeDesc);
        });

        test('non-empty locale on DISPLAYNAME is ignored by open62541 when locale mismatches', () async {
          // open62541 silently ignores writeDisplayName when the locale doesn't
          // match the existing one (new node has empty locale by default).
          // The write returns GOOD but the value is unchanged.
          server!.writeDisplayName(boolNodeId, LocalizedText("Name EN", "en-US"));
          final result = await server!.readAttribute({
            boolNodeId: [AttributeId.UA_ATTRIBUTEID_DISPLAYNAME],
          });
          // Value is NOT updated — this is open62541 behavior, not a bug in our code.
          expect(result[boolNodeId]!.displayName!.value, "the.bool");
        });

        test('overwriting attribute replaces previous value', () async {
          server!.writeDisplayName(boolNodeId, LocalizedText("First", ""));
          server!.writeDisplayName(boolNodeId, LocalizedText("Second", ""));
          final result = await server!.readAttribute({
            boolNodeId: [AttributeId.UA_ATTRIBUTEID_DISPLAYNAME],
          });
          expect(result[boolNodeId]!.displayName!.value, "Second");
        });

        test('overwriting DESCRIPTION replaces previous value', () async {
          server!.writeDescription(boolNodeId, LocalizedText("Desc 1", ""));
          server!.writeDescription(boolNodeId, LocalizedText("Desc 2", ""));
          final result = await server!.readAttribute({
            boolNodeId: [AttributeId.UA_ATTRIBUTEID_DESCRIPTION],
          });
          expect(result[boolNodeId]!.description!.value, "Desc 2");
        });

        test('write VALUE for all basic types', () async {
          // Int
          await server!.write(intNodeId, DynamicValue(value: 999, typeId: NodeId.int32));
          expect(
            (await server!.readAttribute({
              intNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE],
            }))[intNodeId]!.value,
            999,
          );

          // Double
          await server!.write(doubleNodeId, DynamicValue(value: 2.718, typeId: NodeId.double));
          expect(
            (await server!.readAttribute({
              doubleNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE],
            }))[doubleNodeId]!.value,
            closeTo(2.718, 0.001),
          );

          // String
          await server!.write(stringNodeId, DynamicValue(value: "Updated!", typeId: NodeId.uastring));
          expect(
            (await server!.readAttribute({
              stringNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE],
            }))[stringNodeId]!.value,
            "Updated!",
          );
        });
      });

      // ── browse ─────────────────────────────────────────────────────

      group('Server browse', () {
        test('browse Objects folder returns added variables', () {
          final items = server!.browse(NodeId.objectsFolder);
          expect(items, isNotEmpty);
          // Should find our added variable nodes
          final nodeIds = items.map((i) => i.nodeId).toSet();
          expect(nodeIds.contains(boolNodeId), isTrue);
          expect(nodeIds.contains(intNodeId), isTrue);
        });

        test('browse with hierarchical references filter', () {
          final items = server!.browse(
            NodeId.objectsFolder,
            referenceTypeId: NodeId.hierarchicalReferences,
            includeSubtypes: true,
          );
          expect(items, isNotEmpty);
          for (final item in items) {
            expect(item.isForward, isTrue);
          }
        });

        test('browse returns correct displayName and nodeClass', () {
          final items = server!.browse(NodeId.objectsFolder);
          final boolItem = items.firstWhere((i) => i.nodeId == boolNodeId);
          expect(boolItem.nodeClass, NodeClass.UA_NODECLASS_VARIABLE);
          expect(boolItem.displayName, isNotEmpty);
        });

        test('browseTree walks address space with correct depth', () {
          final treeItems = server!.browseTree(
            NodeId.rootFolder,
            maxDepth: 2,
            referenceTypeId: NodeId.hierarchicalReferences,
          );
          expect(treeItems, isNotEmpty);
          for (final item in treeItems) {
            expect(item.depth, greaterThanOrEqualTo(0));
            expect(item.depth, lessThanOrEqualTo(2));
            expect(item.parentNodeId, isNotNull);
          }
          // Should find Objects folder at depth 0
          final objectsFolder = treeItems.where((item) => item.nodeId == NodeId.objectsFolder);
          expect(objectsFolder, isNotEmpty);
          expect(objectsFolder.first.depth, 0);
        });

        test('browseTree is cycle-safe', () {
          // Running browseTree should complete without infinite loop
          final treeItems = server!.browseTree(NodeId.rootFolder, maxDepth: 10);
          expect(treeItems, isNotEmpty);
          // Check no duplicate nodeIds at the same depth/parent
          final seen = <String>{};
          for (final item in treeItems) {
            final key = '${item.nodeId}-${item.parentNodeId}';
            expect(seen.contains(key), isFalse, reason: 'Duplicate: $key');
            seen.add(key);
          }
        });

        test('server browse matches client browse results', () async {
          final serverItems = server!.browse(NodeId.objectsFolder);
          final clientItems = await client!.browse(NodeId.objectsFolder);

          expect(serverItems.length, clientItems.length);
          for (var i = 0; i < serverItems.length; i++) {
            expect(serverItems[i].nodeId, clientItems[i].nodeId);
            expect(serverItems[i].displayName, clientItems[i].displayName);
            expect(serverItems[i].nodeClass, clientItems[i].nodeClass);
            expect(serverItems[i].isForward, clientItems[i].isForward);
          }
        });
      });

      // ── browse edge cases ──────────────────────────────────────

      group('Server browse edge cases', () {
        test('browse leaf node returns empty list', () {
          // Variable nodes have references to their type, but no child nodes
          // with hierarchical references filter, should be empty
          final forwardHierarchical = server!.browse(boolNodeId, referenceTypeId: NodeId.hierarchicalReferences);
          expect(forwardHierarchical, isEmpty);
        });

        test('browse with inverse direction', () {
          final items = server!.browse(
            boolNodeId,
            direction: 1, // inverse
          );
          expect(items, isNotEmpty);
          // Inverse references should point to parent (ObjectsFolder)
          final parentRefs = items.where((i) => i.nodeId == NodeId.objectsFolder);
          expect(parentRefs, isNotEmpty);
        });

        test('browse with both directions', () {
          final items = server!.browse(
            boolNodeId,
            direction: 2, // both
          );
          expect(items, isNotEmpty);
          // Should contain at least the inverse reference to parent
          final hasInverse = items.any((i) => !i.isForward);
          expect(hasInverse, isTrue);
        });

        test('browseTree with maxDepth=0 returns only direct children of root', () {
          final treeItems = server!.browseTree(
            NodeId.rootFolder,
            maxDepth: 0,
            referenceTypeId: NodeId.hierarchicalReferences,
          );
          // maxDepth=0 means we walk at depth 0 only (direct children of root)
          expect(treeItems, isNotEmpty);
          for (final item in treeItems) {
            expect(item.depth, 0);
          }
        });

        test('browseTree with maxDepth=1 includes grandchildren', () {
          final depth0 = server!.browseTree(
            NodeId.rootFolder,
            maxDepth: 0,
            referenceTypeId: NodeId.hierarchicalReferences,
          );
          final depth1 = server!.browseTree(
            NodeId.rootFolder,
            maxDepth: 1,
            referenceTypeId: NodeId.hierarchicalReferences,
          );
          // Depth 1 should have more items than depth 0
          expect(depth1.length, greaterThan(depth0.length));
          // All items should be depth 0 or 1
          for (final item in depth1) {
            expect(item.depth, lessThanOrEqualTo(1));
          }
        });

        test('browseTree on leaf node returns empty', () {
          final treeItems = server!.browseTree(boolNodeId, referenceTypeId: NodeId.hierarchicalReferences);
          // Variable nodes have no hierarchical children to recurse into
          expect(treeItems, isEmpty);
        });
      });

      // ── addObjectNode ──────────────────────────────────────────

      group('Server addObjectNode', () {
        test('creates browseable object node', () {
          final objId = NodeId.fromString(1, 'test.folder');
          server!.addObjectNode(objId, 'TestFolder');

          final items = server!.browse(NodeId.objectsFolder);
          final folderItem = items.where((i) => i.nodeId == objId);
          expect(folderItem, isNotEmpty, reason: 'Object node should appear in Objects folder');
          expect(folderItem.first.nodeClass, NodeClass.UA_NODECLASS_OBJECT);
          expect(folderItem.first.displayName, 'TestFolder');
        });

        test('adds child variable under object node', () {
          final objId = NodeId.fromString(1, 'test.parent');
          server!.addObjectNode(objId, 'ParentFolder');

          final childId = NodeId.fromString(1, 'test.child');
          server!.addVariableNode(
            childId,
            DynamicValue(value: 42, typeId: NodeId.int32, name: 'child_var'),
            parentNodeId: objId,
          );

          final children = server!.browse(objId);
          final childItem = children.where((i) => i.nodeId == childId);
          expect(childItem, isNotEmpty, reason: 'Variable should be child of object node');
          expect(childItem.first.nodeClass, NodeClass.UA_NODECLASS_VARIABLE);
        });

        test('client can browse server-created object node', () async {
          final objId = NodeId.fromString(1, 'test.browseable');
          server!.addObjectNode(objId, 'BrowseableFolder');

          server!.addVariableNode(
            NodeId.fromString(1, 'test.browseable.var'),
            DynamicValue(value: 'hello', typeId: NodeId.uastring, name: 'browse_var'),
            parentNodeId: objId,
          );

          final items = await client!.browse(objId);
          expect(items, isNotEmpty);
          final varItem = items.where((i) => i.nodeId == NodeId.fromString(1, 'test.browseable.var'));
          expect(varItem, isNotEmpty);
        });

        test('nested object nodes', () {
          final parentId = NodeId.fromString(1, 'test.level1');
          final childId = NodeId.fromString(1, 'test.level2');

          server!.addObjectNode(parentId, 'Level1');
          server!.addObjectNode(childId, 'Level2', parentNodeId: parentId);

          final children = server!.browse(parentId);
          final childItem = children.where((i) => i.nodeId == childId);
          expect(childItem, isNotEmpty);
          expect(childItem.first.nodeClass, NodeClass.UA_NODECLASS_OBJECT);
        });
      });

      // ── monitorVariable ────────────────────────────────────────

      group('Server monitorVariable', () {
        test('emits write event when client writes', () async {
          final events = <(String, DynamicValue?)>[];
          final completer = Completer<void>();

          final sub = server!.monitorVariable(intNodeId);
          final listener = sub.listen((event) {
            if (event.$1 == 'write') {
              events.add(event);
              if (!completer.isCompleted) completer.complete();
            }
          });

          // Write from client
          await client!.write(intNodeId, DynamicValue(value: 999, typeId: NodeId.int32));

          await completer.future.timeout(Duration(seconds: 5));
          await listener.cancel();

          expect(events, isNotEmpty);
          expect(events.first.$1, 'write');
          expect(events.first.$2, isNotNull);
          expect(events.first.$2!.value, 999);
        });

        test('emits read event when client reads', () async {
          final events = <(String, DynamicValue?)>[];
          final completer = Completer<void>();

          final sub = server!.monitorVariable(boolNodeId);
          final listener = sub.listen((event) {
            if (event.$1 == 'read') {
              events.add(event);
              if (!completer.isCompleted) completer.complete();
            }
          });

          // Read from client
          await client!.read(boolNodeId);

          await completer.future.timeout(Duration(seconds: 5));
          await listener.cancel();

          expect(events, isNotEmpty);
          expect(events.first.$1, 'read');
          expect(events.first.$2, isNull);
        });

        test('cancel stops notifications', () async {
          final events = <(String, DynamicValue?)>[];

          final sub = server!.monitorVariable(intNodeId);
          final listener = sub.listen((event) {
            events.add(event);
          });

          await client!.write(intNodeId, DynamicValue(value: 10, typeId: NodeId.int32));
          await Future.delayed(Duration(milliseconds: 100));

          final countAfterFirst = events.length;
          expect(countAfterFirst, greaterThan(0));

          // Cancel the monitor
          await listener.cancel();

          // Write again — should not increase event count
          await client!.write(intNodeId, DynamicValue(value: 20, typeId: NodeId.int32));
          await Future.delayed(Duration(milliseconds: 100));

          expect(events.length, countAfterFirst, reason: 'No events after cancel');
        });
      });

      // ── addMethodNode ──────────────────────────────────────────

      group('Server addMethodNode', () {
        test('method with no args and no return', () async {
          var called = false;
          final methodNodeId = NodeId.fromString(1, 'test.method.noargs');

          server!.addMethodNode(
            methodNodeId,
            'NoArgsMethod',
            callback: (inputs) {
              called = true;
              return [];
            },
            parentNodeId: NodeId.fromNumeric(0, 85), // ObjectsFolder
          );

          final result = await client!.call(NodeId.fromNumeric(0, 85), methodNodeId, []);
          expect(called, isTrue);
          expect(result, isEmpty);
        });

        test('method receives input and returns output', () async {
          final methodNodeId = NodeId.fromString(1, 'test.method.double');

          server!.addMethodNode(
            methodNodeId,
            'DoubleIt',
            callback: (inputs) {
              final inputVal = inputs.first.value as int;
              return [DynamicValue(value: inputVal * 2, typeId: NodeId.int32)];
            },
            inputArguments: [DynamicValue(name: 'value', typeId: NodeId.int32)],
            outputArguments: [DynamicValue(name: 'result', typeId: NodeId.int32)],
            parentNodeId: NodeId.fromNumeric(0, 85),
          );

          final result = await client!.call(NodeId.fromNumeric(0, 85), methodNodeId, [
            DynamicValue(value: 21, typeId: NodeId.int32),
          ]);
          expect(result.length, 1);
          expect(result.first.value, 42);
        });

        test('method with multiple inputs and outputs', () async {
          final methodNodeId = NodeId.fromString(1, 'test.method.multi');

          server!.addMethodNode(
            methodNodeId,
            'AddAndMultiply',
            callback: (inputs) {
              final a = inputs[0].value as int;
              final b = inputs[1].value as int;
              return [
                DynamicValue(value: a + b, typeId: NodeId.int32),
                DynamicValue(value: a * b, typeId: NodeId.int32),
              ];
            },
            inputArguments: [
              DynamicValue(name: 'a', typeId: NodeId.int32),
              DynamicValue(name: 'b', typeId: NodeId.int32),
            ],
            outputArguments: [
              DynamicValue(name: 'sum', typeId: NodeId.int32),
              DynamicValue(name: 'product', typeId: NodeId.int32),
            ],
            parentNodeId: NodeId.fromNumeric(0, 85),
          );

          final result = await client!.call(NodeId.fromNumeric(0, 85), methodNodeId, [
            DynamicValue(value: 3, typeId: NodeId.int32),
            DynamicValue(value: 7, typeId: NodeId.int32),
          ]);
          expect(result.length, 2);
          expect(result[0].value, 10); // 3 + 7
          expect(result[1].value, 21); // 3 * 7
        });

        test('method under object node', () async {
          final objectNodeId = NodeId.fromString(1, 'test.method.container');
          final methodNodeId = NodeId.fromString(1, 'test.method.greet');

          server!.addObjectNode(objectNodeId, 'MethodContainer');
          server!.addMethodNode(
            methodNodeId,
            'Greet',
            callback: (inputs) {
              final name = inputs.first.value as String;
              return [DynamicValue(value: 'Hello, $name!', typeId: NodeId.uastring)];
            },
            inputArguments: [DynamicValue(name: 'name', typeId: NodeId.uastring)],
            outputArguments: [DynamicValue(name: 'greeting', typeId: NodeId.uastring)],
            parentNodeId: objectNodeId,
            referenceTypeId: NodeId.fromNumeric(0, 47), // HasComponent
          );

          final result = await client!.call(objectNodeId, methodNodeId, [
            DynamicValue(value: 'World', typeId: NodeId.uastring),
          ]);
          expect(result.length, 1);
          expect(result.first.value, 'Hello, World!');
        });
      });
    });
  }

  // ── Username/password authentication (no TLS) ──
  group('Server auth (no TLS)', () {
    int port = Random().nextInt(10000) + 4840;
    Server? server;

    tearDown(() async {
      stopServerLoop();
      await Future.delayed(Duration(milliseconds: 20));
      server?.shutdown();
      server?.delete();
      server = null;
    });

    test('rejects anonymous when allowAnonymous=false', () async {
      server = setupServer(port, users: {'testuser': 'testpass'}, allowAnonymous: false, allowNonePolicyPassword: true);
      addBasicVariables(server!);

      // Client.connect waits for session activation which never happens
      // when auth is rejected, so use a short timeout to detect the rejection.
      final client = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
      bool running = true;
      unawaited(() async {
        while (running && client.runIterate(Duration(milliseconds: 10))) {
          await Future.delayed(Duration(milliseconds: 5));
        }
      }());
      final connected = client
          .connect("opc.tcp://localhost:$port")
          .timeout(Duration(seconds: 5))
          .then((_) => true)
          .catchError((_) => false);
      expect(await connected, false);
      running = false;
      await client.delete();
    });

    test('accepts correct credentials', () async {
      server = setupServer(port, users: {'testuser': 'testpass'}, allowAnonymous: false, allowNonePolicyPassword: true);
      addBasicVariables(server!);

      final client = await setupClientWithAuth(port, username: 'testuser', password: 'testpass');
      final result = await client.read(boolNodeId);
      expect(result.value, true);
      client.disconnect();
      await client.delete();
    });

    test('rejects wrong password', () async {
      server = setupServer(port, users: {'testuser': 'testpass'}, allowAnonymous: false, allowNonePolicyPassword: true);
      addBasicVariables(server!);

      final client = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL, username: 'testuser', password: 'wrongpass');
      bool running = true;
      unawaited(() async {
        while (running && client.runIterate(Duration(milliseconds: 10))) {
          await Future.delayed(Duration(milliseconds: 5));
        }
      }());
      final connected = client
          .connect("opc.tcp://localhost:$port")
          .timeout(Duration(seconds: 5))
          .then((_) => true)
          .catchError((_) => false);
      expect(await connected, false);
      running = false;
      await client.delete();
    });

    test('allows anonymous when allowAnonymous=true', () async {
      server = setupServer(port, users: {'admin': 'admin123'}, allowAnonymous: true, allowNonePolicyPassword: true);
      addBasicVariables(server!);

      // Anonymous client works
      final anonClient = await setupClient(port);
      final result = await anonClient.read(boolNodeId);
      expect(result.value, true);
      anonClient.disconnect();
      await anonClient.delete();

      // Authenticated client also works
      final authClient = await setupClientWithAuth(port, username: 'admin', password: 'admin123');
      final result2 = await authClient.read(boolNodeId);
      expect(result2.value, true);
      authClient.disconnect();
      await authClient.delete();
    });
  });

  // ── TLS with certificates ──
  group('Server TLS', () {
    int port = Random().nextInt(10000) + 4840;
    Server? server;
    late Uint8List cert;
    late Uint8List key;

    setUpAll(() {
      cert = File('client_cert.der').readAsBytesSync();
      key = File('client_key.der').readAsBytesSync();
    });

    tearDown(() async {
      stopServerLoop();
      await Future.delayed(Duration(milliseconds: 20));
      server?.shutdown();
      server?.delete();
      server = null;
    });

    test('accepts encrypted connection (SignAndEncrypt)', () async {
      server = setupServer(port, certificate: cert, privateKey: key);
      addBasicVariables(server!);

      final client = await setupClientWithAuth(
        port,
        certificate: cert,
        privateKey: key,
        securityMode: MessageSecurityMode.UA_MESSAGESECURITYMODE_SIGNANDENCRYPT,
      );
      final result = await client.read(boolNodeId);
      expect(result.value, true);
      client.disconnect();
      await client.delete();
    });

    test('still allows None policy (unencrypted)', () async {
      server = setupServer(port, certificate: cert, privateKey: key);
      addBasicVariables(server!);

      final client = await setupClient(port);
      final result = await client.read(boolNodeId);
      expect(result.value, true);
      client.disconnect();
      await client.delete();
    });
  });

  // ── TLS + auth combined ──
  group('Server TLS + auth', () {
    int port = Random().nextInt(10000) + 4840;
    Server? server;
    late Uint8List cert;
    late Uint8List key;

    setUpAll(() {
      cert = File('client_cert.der').readAsBytesSync();
      key = File('client_key.der').readAsBytesSync();
    });

    tearDown(() async {
      stopServerLoop();
      await Future.delayed(Duration(milliseconds: 20));
      server?.shutdown();
      server?.delete();
      server = null;
    });

    test('TLS + auth with correct credentials succeeds', () async {
      server = setupServer(
        port,
        certificate: cert,
        privateKey: key,
        users: {'secureuser': 'securepass'},
        allowAnonymous: false,
      );
      addBasicVariables(server!);

      final client = await setupClientWithAuth(
        port,
        certificate: cert,
        privateKey: key,
        securityMode: MessageSecurityMode.UA_MESSAGESECURITYMODE_SIGNANDENCRYPT,
        username: 'secureuser',
        password: 'securepass',
      );
      final result = await client.read(boolNodeId);
      expect(result.value, true);
      client.disconnect();
      await client.delete();
    });
  });
}
