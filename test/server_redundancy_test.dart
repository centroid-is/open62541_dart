import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'common.dart';

/// Redundancy as a server feature (#109): `Server.setRedundancy` publishes a
/// non-transparent redundant set the Part 5 way, on top of two generic
/// building blocks, `addObjectTypeNode` and `setTypeDefinition`.
///
/// open62541's reduced NS0 types `Server/ServerRedundancy` (i=2296) as the
/// base `ServerRedundancyType` (i=2034), whose `RedundancySupport` must be
/// None (Part 5 §6.3.7); `NonTransparentRedundancyType` (i=2039) and the
/// `ServerUriArray` instance (i=11314) are not in the nodeset. Everything
/// here is checked through a `Client`: what a client sees is what counts.
NodeId ns0(int id) => NodeId.fromNumeric(0, id);

// The NS0 nodes without a `NodeId` static.
final serverRedundancyType = ns0(raw.UA_NS0ID_SERVERREDUNDANCYTYPE);
final nonTransparentRedundancyType = ns0(raw.UA_NS0ID_NONTRANSPARENTREDUNDANCYTYPE);
final hasModellingRule = ns0(raw.UA_NS0ID_HASMODELLINGRULE);
final mandatory = ns0(raw.UA_NS0ID_MODELLINGRULE_MANDATORY);

void main() {
  late Server server;
  late Client client;

  setUp(() async {
    server = setupServer();
    client = await setupClient(server.port);
  });

  tearDown(() async {
    await client.delete();
    server.shutdown();
    server.delete();
  });

  /// The targets of [node]'s HasTypeDefinition references, as a client sees them.
  Future<List<NodeId>> typeDefinitionOf(NodeId node) async {
    final refs = await client.browse(node, referenceTypeId: NodeId.hasTypeDefinition);
    return refs.map((r) => r.nodeId).toList();
  }

  /// The ServerUriArray as a client reads it.
  Future<List<String>> readServerUris() async =>
      (await client.read(NodeId.serverUriArray)).asArray.map((v) => v.asString).toList();

  /// This server's ApplicationUri, as a client learns it: ServerArray[0].
  Future<String> ownUri() async => (await client.read(NodeId.serverArray)).asArray.first.asString;

  /// One attribute of [node] (`readAttribute` merges the attributes of a node
  /// into one DynamicValue, so ValueRank and ArrayDimensions are read apart).
  Future<DynamicValue> attribute(NodeId node, AttributeId id) async => (await client.readAttribute({
    node: [id],
  }))[node]!;

  /// Adds a mandatory Property [nodeId] named [name] with [value] under [parent].
  void addMandatoryProperty(NodeId nodeId, NodeId parent, String name, DynamicValue value) {
    server.addVariableNode(
      nodeId,
      value..name = name,
      parentNodeId: parent,
      parentReferenceNodeId: NodeId.hasProperty,
      baseDataVariableType: NodeId.propertyType,
    );
    server.addReference(nodeId, hasModellingRule, mandatory);
  }

  group('addObjectTypeNode', () {
    final pumpType = NodeId.fromString(1, 'PumpType');
    final speed = NodeId.fromString(1, 'PumpType.Speed');

    test(
      'a custom ObjectType is a subtype of BaseObjectType, and its mandatory property is copied onto instances',
      () async {
        server.addObjectTypeNode(pumpType, 'PumpType', displayName: LocalizedText('Pump type', 'en'));
        addMandatoryProperty(speed, pumpType, 'Speed', DynamicValue(value: 7.5, typeId: NodeId.double));

        final subtypes = await client.browse(NodeId.baseObjectType, referenceTypeId: NodeId.hasSubtype);
        final pump = subtypes.singleWhere((t) => t.nodeId == pumpType);
        expect(pump.nodeClass, NodeClass.UA_NODECLASS_OBJECTTYPE);
        expect(pump.browseName, 'PumpType');
        expect(pump.displayName, 'Pump type');

        final pump1 = NodeId.fromString(1, 'Pump1');
        server.addObjectNode(pump1, browseName: 'Pump1', typeDefinition: pumpType);
        expect(await typeDefinitionOf(pump1), [pumpType]);

        // The instance has its own Speed: a copy of the declaration (a fresh
        // NodeId) carrying the declared value.
        final properties = await client.browse(pump1, referenceTypeId: NodeId.hasProperty);
        expect(properties.map((p) => p.browseName), ['Speed']);
        expect(properties.single.nodeId, isNot(speed));
        expect((await client.read(properties.single.nodeId)).asDouble, 7.5);
      },
    );

    test('a property without the Mandatory modelling rule stays on the type', () async {
      server.addObjectTypeNode(pumpType, 'PumpType');
      server.addVariableNode(
        speed,
        DynamicValue(name: 'Speed', value: 1.0, typeId: NodeId.double),
        parentNodeId: pumpType,
        parentReferenceNodeId: NodeId.hasProperty,
        baseDataVariableType: NodeId.propertyType,
      );
      final pump1 = NodeId.fromString(1, 'Pump1');
      server.addObjectNode(pump1, browseName: 'Pump1', typeDefinition: pumpType);
      expect(await client.browse(pump1, referenceTypeId: NodeId.hasProperty), isEmpty);
    });

    test('a subtype of a custom type inherits its mandatory property', () async {
      server.addObjectTypeNode(pumpType, 'PumpType', isAbstract: true);
      addMandatoryProperty(speed, pumpType, 'Speed', DynamicValue(value: 2.0, typeId: NodeId.double));
      final centrifugal = NodeId.fromString(1, 'CentrifugalPumpType');
      server.addObjectTypeNode(centrifugal, 'CentrifugalPumpType', parentType: pumpType);
      expect((await client.browse(pumpType, referenceTypeId: NodeId.hasSubtype)).map((t) => t.nodeId), [centrifugal]);

      final pump1 = NodeId.fromString(1, 'Pump1');
      server.addObjectNode(pump1, browseName: 'Pump1', typeDefinition: centrifugal);
      final properties = await client.browse(pump1, referenceTypeId: NodeId.hasProperty);
      expect(properties.map((p) => p.browseName), ['Speed']);
    });

    test('open62541 refusals surface as UaStatusException', () async {
      server.addObjectTypeNode(pumpType, 'PumpType');
      expect(
        () => server.addObjectTypeNode(pumpType, 'PumpType'),
        throwsA(isA<UaStatusException>().having((e) => e.statusCode, 'status', raw.UA_STATUSCODE_BADNODEIDEXISTS)),
      );
      // A VariableType is no parent for an ObjectType.
      expect(
        () => server.addObjectTypeNode(NodeId.fromString(1, 'Odd'), 'Odd', parentType: NodeId.propertyType),
        throwsA(isA<UaStatusException>()),
      );
    });
  });

  group('setTypeDefinition', () {
    final tankType = NodeId.fromString(1, 'TankType');
    final tank = NodeId.fromString(1, 'Tank1');

    test('a client browsing the object sees the new type, and only it', () async {
      server.addObjectNode(tank, browseName: 'Tank1');
      server.addObjectTypeNode(tankType, 'TankType');
      expect(await typeDefinitionOf(tank), [NodeId.baseObjectType]);

      server.setTypeDefinition(tank, tankType);

      expect(await typeDefinitionOf(tank), [tankType]);
      // The type also travels in the browse of the parent (ReferenceDescription.typeDefinition).
      final fromParent = await client.browse(NodeId.objectsFolder);
      expect(fromParent.singleWhere((r) => r.nodeId == tank).typeDefinition, tankType);
      // The inverse reference moved too: the old type no longer lists the object.
      final baseInstances = await client.browse(
        NodeId.baseObjectType,
        direction: 1,
        referenceTypeId: NodeId.hasTypeDefinition,
      );
      expect(baseInstances.map((r) => r.nodeId), isNot(contains(tank)));
      final newInstances = await client.browse(tankType, direction: 1, referenceTypeId: NodeId.hasTypeDefinition);
      expect(newInstances.map((r) => r.nodeId), [tank]);
    });

    test('a missing object or type is refused before anything changes', () async {
      server.addObjectNode(tank, browseName: 'Tank1');
      expect(
        () => server.setTypeDefinition(NodeId.fromString(1, 'nope'), tankType),
        throwsA(isA<UaStatusException>().having((e) => e.statusCode, 'status', raw.UA_STATUSCODE_BADNODEIDUNKNOWN)),
      );
      expect(
        () => server.setTypeDefinition(tank, tankType),
        throwsA(
          isA<UaStatusException>().having((e) => e.statusCode, 'status', raw.UA_STATUSCODE_BADTYPEDEFINITIONINVALID),
        ),
      );
      expect(await typeDefinitionOf(tank), [NodeId.baseObjectType]);
    });

    test('retyping to the current type is a no-op', () async {
      server.addObjectNode(tank, browseName: 'Tank1');
      server.setTypeDefinition(tank, NodeId.baseObjectType);
      expect(await typeDefinitionOf(tank), [NodeId.baseObjectType]);
    });
  });

  group('setRedundancy', () {
    const uris = ['urn:plant:opcua:a', 'urn:plant:opcua:b'];

    test('the reduced NS0 as shipped: base type, None, no ServerUriArray', () async {
      expect(await typeDefinitionOf(NodeId.serverRedundancy), [serverRedundancyType]);
      expect((await client.read(NodeId.redundancySupport)).asInt, RedundancySupport.none.value);
      expect(
        await client.browse(NodeId.serverRedundancy, referenceTypeId: NodeId.hasProperty),
        isNot(contains(NodeId.serverUriArray)),
      );
      expect(await client.browse(serverRedundancyType, referenceTypeId: NodeId.hasSubtype), isEmpty);
    });

    test('hot: a client sees NonTransparentRedundancyType, RedundancySupport 3 and the ServerUriArray', () async {
      server.setRedundancy(RedundancySupport.hot, serverUris: uris);

      expect(await typeDefinitionOf(NodeId.serverRedundancy), [nonTransparentRedundancyType]);
      expect((await client.read(NodeId.redundancySupport)).asInt, 3);
      // Part 5 §6.3.9: the local server is in the array; it was not in the
      // caller's list, so it leads.
      final own = await ownUri();
      expect(own, isNotEmpty);
      expect(await readServerUris(), [own, ...uris]);

      // The property is a 0:ServerUriArray of PropertyType under ServerRedundancy.
      final properties = await client.browse(NodeId.serverRedundancy, referenceTypeId: NodeId.hasProperty);
      final property = properties.singleWhere((p) => p.nodeId == NodeId.serverUriArray);
      expect(property.browseName, 'ServerUriArray');
      expect(property.typeDefinition, NodeId.propertyType);

      // The type is a subtype of ServerRedundancyType with the mandatory
      // ServerUriArray declaration (i=2040), as Part 5 defines it.
      final subtypes = await client.browse(serverRedundancyType, referenceTypeId: NodeId.hasSubtype);
      expect(subtypes.map((t) => t.nodeId), [nonTransparentRedundancyType]);
      expect(subtypes.single.browseName, 'NonTransparentRedundancyType');
      final declarations = await client.browse(nonTransparentRedundancyType, referenceTypeId: NodeId.hasProperty);
      final declaration = declarations.singleWhere((p) => p.browseName == 'ServerUriArray');
      expect(declaration.nodeId, ns0(raw.UA_NS0ID_NONTRANSPARENTREDUNDANCYTYPE_SERVERURIARRAY));
      final rule = await client.browse(declaration.nodeId, referenceTypeId: hasModellingRule);
      expect(rule.map((r) => r.nodeId), [mandatory]);
    });

    test('none keeps the base type and reports None', () async {
      server.setRedundancy(RedundancySupport.none);
      expect(await typeDefinitionOf(NodeId.serverRedundancy), [serverRedundancyType]);
      expect((await client.read(NodeId.redundancySupport)).asInt, 0);
      expect(await client.browse(serverRedundancyType, referenceTypeId: NodeId.hasSubtype), isEmpty);
    });

    test('calling again updates the mode and the array; none takes the set down again', () async {
      server.setRedundancy(RedundancySupport.hot, serverUris: uris);
      final own = await ownUri();
      server.setRedundancy(RedundancySupport.warm, serverUris: [...uris, 'urn:plant:opcua:c']);

      expect(await typeDefinitionOf(NodeId.serverRedundancy), [nonTransparentRedundancyType]);
      expect((await client.read(NodeId.redundancySupport)).asInt, 2);
      expect(await readServerUris(), [own, ...uris, 'urn:plant:opcua:c']);
      // Still one type and one property, not a second copy of either.
      expect(await client.browse(serverRedundancyType, referenceTypeId: NodeId.hasSubtype), hasLength(1));
      expect(
        (await client.browse(
          NodeId.serverRedundancy,
          referenceTypeId: NodeId.hasProperty,
        )).where((p) => p.nodeId == NodeId.serverUriArray),
        hasLength(1),
      );

      server.setRedundancy(RedundancySupport.none);
      expect(await typeDefinitionOf(NodeId.serverRedundancy), [serverRedundancyType]);
      expect((await client.read(NodeId.redundancySupport)).asInt, 0);
      final properties = await client.browse(NodeId.serverRedundancy, referenceTypeId: NodeId.hasProperty);
      expect(properties.map((p) => p.nodeId), isNot(contains(NodeId.serverUriArray)));

      // And up once more, reusing the type that is still there.
      server.setRedundancy(RedundancySupport.cold, serverUris: ['urn:plant:opcua:a']);
      expect(await typeDefinitionOf(NodeId.serverRedundancy), [nonTransparentRedundancyType]);
      expect((await client.read(NodeId.redundancySupport)).asInt, 1);
      expect(await readServerUris(), [own, 'urn:plant:opcua:a']);
    });

    test('the local server is in ServerUriArray: prepended when absent, kept in place when given', () async {
      final own = await ownUri();
      server.setRedundancy(RedundancySupport.hot, serverUris: ['urn:peer']);
      expect(await readServerUris(), [own, 'urn:peer']);

      // Given by the caller, in its position, and not twice.
      server.setRedundancy(RedundancySupport.hot, serverUris: ['urn:peer', own]);
      expect(await readServerUris(), ['urn:peer', own]);
    });

    test(
      'ServerUriArray is a one-dimensional String array: ValueRank 1, ArrayDimensions [0], on the instance and the declaration',
      () async {
        server.setRedundancy(RedundancySupport.hot, serverUris: uris);
        for (final node in [NodeId.serverUriArray, ns0(raw.UA_NS0ID_NONTRANSPARENTREDUNDANCYTYPE_SERVERURIARRAY)]) {
          expect((await attribute(node, AttributeId.UA_ATTRIBUTEID_VALUERANK)).asInt, 1, reason: '$node');
          final dimensions = await attribute(node, AttributeId.UA_ATTRIBUTEID_ARRAYDIMENSIONS);
          expect(dimensions.asArray.map((d) => d.asInt), [0], reason: '$node');
          expect((await attribute(node, AttributeId.UA_ATTRIBUTEID_DATATYPE)).typeId, NodeId.uastring, reason: '$node');
        }
      },
    );

    test('an unusable argument throws ArgumentError and changes nothing', () async {
      expect(() => server.setRedundancy(RedundancySupport.hot, serverUris: []), throwsArgumentError);
      expect(() => server.setRedundancy(RedundancySupport.hot), throwsArgumentError);
      expect(() => server.setRedundancy(RedundancySupport.none, serverUris: uris), throwsArgumentError);
      expect(() => server.setRedundancy(RedundancySupport.transparent, serverUris: uris), throwsArgumentError);
      expect(await typeDefinitionOf(NodeId.serverRedundancy), [serverRedundancyType]);
      expect((await client.read(NodeId.redundancySupport)).asInt, 0);
    });

    test('configured before start(), as a server normally is, and startup keeps it', () async {
      // open62541 deletes the standard ServerUriArray when the server is
      // created (UA_Server_init -> initNS0 -> configureNS0, ua_server.c:575,
      // ua_server_ns0.c:1037), not in UA_Server_run_startup, which touches
      // only ServerArray and ServerStatus.StartTime. So what setRedundancy
      // adds after the constructor is still there after start().
      final early = Server(port: 0, logLevel: LogLevel.UA_LOGLEVEL_ERROR);
      early.setRedundancy(RedundancySupport.hotAndMirrored, serverUris: uris);
      early.start();
      () async {
        while (early.runIterate()) {
          await Future.delayed(const Duration(milliseconds: 50));
        }
      }();
      final earlyClient = await setupClient(early.port);
      try {
        final refs = await earlyClient.browse(NodeId.serverRedundancy, referenceTypeId: NodeId.hasTypeDefinition);
        expect(refs.map((r) => r.nodeId), [nonTransparentRedundancyType]);
        expect((await earlyClient.read(NodeId.redundancySupport)).asInt, 5);
        final own = (await earlyClient.read(NodeId.serverArray)).asArray.first.asString;
        expect((await earlyClient.read(NodeId.serverUriArray)).asArray.map((v) => v.asString), [own, ...uris]);
      } finally {
        await earlyClient.delete();
        early.shutdown();
        early.delete();
      }
    });
  });
}
