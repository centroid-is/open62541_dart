import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'common.dart';

/// Integration tests for the structural-node / node-management API on [Server]:
/// [Server.addObjectNode], [Server.addFolderNode], [Server.deleteNode] and
/// [Server.addReference]. An in-process server builds a small hierarchy that a
/// client then browses and reads back.
void main() {
  late int port;
  late Server server;
  late Client client;

  // Standard hierarchical reference types.
  final hasComponent = NodeId.fromNumeric(0, raw.UA_NS0ID_HASCOMPONENT);
  final folderType = NodeId.fromNumeric(0, raw.UA_NS0ID_FOLDERTYPE);

  // Address-space layout built in setUpAll:
  //   Objects
  //     └─ Plant (folder)
  //          └─ Tank1 (object)
  //               ├─ Level (variable)
  //               └─ Temperature (variable)
  final plantFolder = NodeId.fromString(1, 'plant');
  final tankObject = NodeId.fromString(1, 'plant.tank1');
  final levelVar = NodeId.fromString(1, 'plant.tank1.level');
  final tempVar = NodeId.fromString(1, 'plant.tank1.temperature');

  // A separate variable that lives directly under Objects; used to exercise
  // addReference (linking it as a component of Tank1) and deleteNode.
  final looseVar = NodeId.fromString(1, 'loose.var');

  setUpAll(() async {
    port = await freeTcpPort();
    server = setupServer(port);

    // Folder under the Objects folder (default parent).
    server.addFolderNode(plantFolder, 'Plant');

    // Object under the folder, using HasComponent as the parent reference.
    server.addObjectNode(
      tankObject,
      browseName: 'Tank1',
      displayName: 'Tank 1',
      parentNodeId: plantFolder,
      parentReferenceNodeId: hasComponent,
    );

    // Two variables under the object.
    server.addVariableNode(
      levelVar,
      DynamicValue(value: 42.0, typeId: NodeId.double, name: 'Level'),
      parentNodeId: tankObject,
      parentReferenceNodeId: hasComponent,
    );
    server.addVariableNode(
      tempVar,
      DynamicValue(value: 21.5, typeId: NodeId.double, name: 'Temperature'),
      parentNodeId: tankObject,
      parentReferenceNodeId: hasComponent,
    );

    // A loose variable under Objects (default parent).
    server.addVariableNode(looseVar, DynamicValue(value: 7, typeId: NodeId.int32, name: 'Loose'));

    client = await setupClient(port);
  });

  tearDownAll(() async {
    client.disconnect();
    await client.delete();
    server.shutdown();
    server.delete();
  });

  test('addFolderNode creates a FolderType object under Objects', () async {
    final objectsChildren = await client.browse(NodeId.objectsFolder);

    final plant = objectsChildren.where((i) => i.nodeId == plantFolder).toList();
    expect(plant, hasLength(1), reason: 'Plant folder should be a child of Objects');
    expect(plant.first.browseName, 'Plant');
    expect(plant.first.nodeClass, NodeClass.UA_NODECLASS_OBJECT);
    // The type definition of a folder is FolderType.
    expect(plant.first.typeDefinition, folderType);
  });

  test('addObjectNode nests an object under the folder', () async {
    final plantChildren = await client.browse(plantFolder);

    final tank = plantChildren.where((i) => i.nodeId == tankObject).toList();
    expect(tank, hasLength(1), reason: 'Tank1 should be a child of Plant');
    expect(tank.first.browseName, 'Tank1');
    expect(tank.first.displayName, 'Tank 1');
    expect(tank.first.nodeClass, NodeClass.UA_NODECLASS_OBJECT);
  });

  test('variables are reachable under the object', () async {
    final tankChildren = await client.browse(tankObject);

    final browseNames = tankChildren.map((i) => i.browseName).toSet();
    expect(browseNames, containsAll(<String>{'Level', 'Temperature'}));

    // And the values read back through the client.
    expect((await client.read(levelVar)).value, 42.0);
    expect((await client.read(tempVar)).value, 21.5);
  });

  test('browseTree reflects the full hierarchy', () async {
    final tree = await client
        .browseTree(NodeId.objectsFolder, maxDepth: 5, referenceTypeId: NodeId.hierarchicalReferences)
        .toList();

    final ids = tree.map((i) => i.nodeId).toSet();
    expect(ids, containsAll(<NodeId>{plantFolder, tankObject, levelVar, tempVar}));

    // Depth ordering: Plant is shallower than Tank1, which is shallower than
    // its variables.
    int depthOf(NodeId id) => tree.firstWhere((i) => i.nodeId == id).depth;
    expect(depthOf(plantFolder), lessThan(depthOf(tankObject)));
    expect(depthOf(tankObject), lessThan(depthOf(levelVar)));
  });

  test('addReference links an existing node under a new parent', () async {
    // Initially the loose variable is only under Objects, not under Tank1.
    var tankChildren = await client.browse(tankObject);
    expect(tankChildren.any((i) => i.nodeId == looseVar), isFalse);

    // Add a HasComponent reference from Tank1 to the loose variable.
    server.addReference(tankObject, hasComponent, looseVar);

    tankChildren = await client.browse(tankObject);
    final linked = tankChildren.where((i) => i.nodeId == looseVar).toList();
    expect(linked, hasLength(1), reason: 'loose var should now show up under Tank1');
    expect(linked.first.browseName, 'Loose');
    expect(linked.first.isForward, isTrue);
  });

  test('deleteNode removes a variable from the address space', () async {
    // Sanity check: Temperature is present before deletion.
    var tankChildren = await client.browse(tankObject);
    expect(tankChildren.any((i) => i.nodeId == tempVar), isTrue);

    server.deleteNode(tempVar);

    // A subsequent browse of the parent no longer lists it.
    tankChildren = await client.browse(tankObject);
    expect(tankChildren.any((i) => i.nodeId == tempVar), isFalse);

    // Reading the deleted node now errors.
    await expectLater(client.read(tempVar), throwsA(anything));
  });
}
