import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'common.dart';

/// NS0 value-source takeover (backlog: ServiceLevel / RedundancySupport not
/// writable). open62541 1.5 pins `Server/ServiceLevel` (i=2267) at 255 via an
/// internal callback value source and stores RedundancySupport=None in
/// i=3709; both reject regular writes. `Server.setVariableValueSource`
/// replaces the value source of these EXISTING nodes so a redundant server
/// can publish its real service level.
void main() {
  group('NS0 value source takeover', () {
    late int port;
    late Server server;
    late Client client;

    setUp(() async {
      port = await freeTcpPort();
      server = setupServer(port);
      client = await setupClient(port);
    });

    tearDown(() async {
      await client.delete();
      server.shutdown();
      server.delete();
    });

    test('ServiceLevel (i=2267) serves the injected byte, not the pinned 255', () async {
      final serviceLevelId = NodeId.fromNumeric(0, raw.UA_NS0ID_SERVER_SERVICELEVEL);

      // Untouched, open62541's internal callback reports 255.
      final pinned = await client.read(serviceLevelId);
      expect(pinned.asInt, 255);

      var serviceLevel = 250;
      server.setVariableValueSource(
        serviceLevelId,
        onRead: () => DynamicValue(value: serviceLevel, typeId: NodeId.byte),
      );

      expect((await client.read(serviceLevelId)).asInt, 250);

      // A change on the serving side is visible on the next client read.
      serviceLevel = 100;
      expect((await client.read(serviceLevelId)).asInt, 100);
    });

    test('RedundancySupport (i=3709) serves the injected enum value', () async {
      final redundancySupportId = NodeId.fromNumeric(0, raw.UA_NS0ID_SERVER_SERVERREDUNDANCY_REDUNDANCYSUPPORT);

      // open62541 stores RedundancySupport=None (0) at NS0 init.
      expect((await client.read(redundancySupportId)).asInt, 0);

      const redundancySupportHot = 3; // OPC UA Part 5 RedundancySupport.Hot
      server.setVariableValueSource(
        redundancySupportId,
        onRead: () => DynamicValue(value: redundancySupportHot, typeId: NodeId.int32),
      );

      expect((await client.read(redundancySupportId)).asInt, redundancySupportHot);
    });

    test('ServerUriArray can be added back under ServerRedundancy', () async {
      // open62541 deletes the standard ServerUriArray property (i=11314) from
      // NS0 at startup ("Remove unused subtypes of ServerRedundancy"), so it
      // must be re-added as a HasProperty child of ServerRedundancy (i=2296).
      final serverUriArrayId = NodeId.fromNumeric(0, raw.UA_NS0ID_SERVER_SERVERREDUNDANCY_SERVERURIARRAY);
      final uris = DynamicValue.fromList(
        ['urn:server:a', 'urn:server:b'],
        typeId: NodeId.uastring,
        name: 'ServerUriArray',
      );
      server.addVariableNode(
        serverUriArrayId,
        uris,
        accessLevel: AccessLevelMask(read: true),
        parentNodeId: NodeId.fromNumeric(0, raw.UA_NS0ID_SERVER_SERVERREDUNDANCY),
        parentReferenceNodeId: NodeId.fromNumeric(0, raw.UA_NS0ID_HASPROPERTY),
        baseDataVariableType: NodeId.fromNumeric(0, raw.UA_NS0ID_PROPERTYTYPE),
        typeId: NodeId.uastring,
      );

      final read = await client.read(serverUriArrayId);
      expect(read.isArray, isTrue);
      expect(read.asArray.map((v) => v.asString).toList(), ['urn:server:a', 'urn:server:b']);
    });
  });
}
