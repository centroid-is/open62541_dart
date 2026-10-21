// #110: the well-known NS0 nodes an application reads or extends (the Server
// object and its status, service level, namespace and redundancy surface,
// and the reference and type nodes standard properties are added with) were
// only reachable through the generated `UA_NS0ID_*` constants, an
// implementation import. They are `NodeId` statics now, each backed by the
// generated constant.

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'common.dart';

void main() {
  test('every NS0 static is the generated constant in namespace 0', () {
    final expected = <NodeId, int>{
      NodeId.rootFolder: raw.UA_NS0ID_ROOTFOLDER,
      NodeId.objectsFolder: raw.UA_NS0ID_OBJECTSFOLDER,
      NodeId.typesFolder: raw.UA_NS0ID_TYPESFOLDER,
      NodeId.viewsFolder: raw.UA_NS0ID_VIEWSFOLDER,
      NodeId.server: raw.UA_NS0ID_SERVER,
      NodeId.serverArray: raw.UA_NS0ID_SERVER_SERVERARRAY,
      NodeId.namespaceArray: raw.UA_NS0ID_SERVER_NAMESPACEARRAY,
      NodeId.serverStatus: raw.UA_NS0ID_SERVER_SERVERSTATUS,
      NodeId.serverStatusStartTime: raw.UA_NS0ID_SERVER_SERVERSTATUS_STARTTIME,
      NodeId.serverStatusCurrentTime: raw.UA_NS0ID_SERVER_SERVERSTATUS_CURRENTTIME,
      NodeId.serverStatusState: raw.UA_NS0ID_SERVER_SERVERSTATUS_STATE,
      NodeId.serverStatusBuildInfo: raw.UA_NS0ID_SERVER_SERVERSTATUS_BUILDINFO,
      NodeId.serviceLevel: raw.UA_NS0ID_SERVER_SERVICELEVEL,
      NodeId.serverRedundancy: raw.UA_NS0ID_SERVER_SERVERREDUNDANCY,
      NodeId.redundancySupport: raw.UA_NS0ID_SERVER_SERVERREDUNDANCY_REDUNDANCYSUPPORT,
      NodeId.serverUriArray: raw.UA_NS0ID_SERVER_SERVERREDUNDANCY_SERVERURIARRAY,
      NodeId.hierarchicalReferences: raw.UA_NS0ID_HIERARCHICALREFERENCES,
      NodeId.hasSubtype: raw.UA_NS0ID_HASSUBTYPE,
      NodeId.organizes: raw.UA_NS0ID_ORGANIZES,
      NodeId.hasComponent: raw.UA_NS0ID_HASCOMPONENT,
      NodeId.hasProperty: raw.UA_NS0ID_HASPROPERTY,
      NodeId.hasTypeDefinition: raw.UA_NS0ID_HASTYPEDEFINITION,
      NodeId.baseObjectType: raw.UA_NS0ID_BASEOBJECTTYPE,
      NodeId.folderType: raw.UA_NS0ID_FOLDERTYPE,
      NodeId.baseDataVariableType: raw.UA_NS0ID_BASEDATAVARIABLETYPE,
      NodeId.propertyType: raw.UA_NS0ID_PROPERTYTYPE,
    };
    expected.forEach((id, numeric) {
      expect(id, NodeId.fromNumeric(0, numeric));
      expect(id.namespace, 0);
      expect(id.numeric, numeric);
    });
    // Twenty-six distinct nodes: no two statics share a constant.
    expect(expected.keys.toSet().length, expected.length);
  });

  test('the statics name live nodes: ServerStatus/CurrentTime reads as a DateTime', () async {
    final server = setupServer();
    addTearDown(() {
      server.shutdown();
      server.delete();
    });
    final client = await setupClient(server.port);
    addTearDown(client.delete);

    final before = DateTime.now().toUtc().subtract(const Duration(seconds: 1));
    final currentTime = await client.read(NodeId.serverStatusCurrentTime);
    expect(currentTime.value, isA<DateTime>());
    expect(currentTime.type, DynamicType.datetime);
    expect(currentTime.asDateTime!.toUtc().isAfter(before), isTrue, reason: 'read ${currentTime.asDateTime}');

    // The service level and namespace array are there as well.
    expect((await client.read(NodeId.serviceLevel)).asIntOrNull, isNotNull);
    final namespaces = await client.read(NodeId.namespaceArray);
    expect(namespaces.isArray, isTrue);
    expect(namespaces.asArray.first.asString, 'http://opcfoundation.org/UA/');
  }, timeout: Timeout(Duration(seconds: 30)));
}
