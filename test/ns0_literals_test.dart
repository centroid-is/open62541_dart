// The namespace-0 identifiers on NodeId are written as literals in
// node_id_core.dart, because reading them from the generated bindings is
// exactly what would pull `dart:ffi` into the one file that must not have it.
//
// This test is the price of that: every literal is checked against the
// generated constant it stands in for, so a regenerated binding that moves a
// number fails here instead of silently addressing the wrong node at runtime.
// It is a native test on purpose — it needs the bindings to compare against.

import 'dart:io';

import 'package:test/test.dart';

import 'package:open62541/open62541_types.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;

void main() {
  final expected = <String, ({NodeId actual, int generated})>{
    // Data types.
    'nullId': (actual: NodeId.nullId, generated: 0),
    'boolean': (actual: NodeId.boolean, generated: raw.UA_NS0ID_BOOLEAN),
    'sbyte': (actual: NodeId.sbyte, generated: raw.UA_NS0ID_SBYTE),
    'byte': (actual: NodeId.byte, generated: raw.UA_NS0ID_BYTE),
    'int16': (actual: NodeId.int16, generated: raw.UA_NS0ID_INT16),
    'uint16': (actual: NodeId.uint16, generated: raw.UA_NS0ID_UINT16),
    'int32': (actual: NodeId.int32, generated: raw.UA_NS0ID_INT32),
    'uint32': (actual: NodeId.uint32, generated: raw.UA_NS0ID_UINT32),
    'int64': (actual: NodeId.int64, generated: raw.UA_NS0ID_INT64),
    'uint64': (actual: NodeId.uint64, generated: raw.UA_NS0ID_UINT64),
    'float': (actual: NodeId.float, generated: raw.UA_NS0ID_FLOAT),
    'double': (actual: NodeId.double, generated: raw.UA_NS0ID_DOUBLE),
    'uastring': (actual: NodeId.uastring, generated: raw.UA_NS0ID_STRING),
    'datetime': (actual: NodeId.datetime, generated: raw.UA_NS0ID_DATETIME),
    'nodeId': (actual: NodeId.nodeId, generated: raw.UA_NS0ID_NODEID),
    'localizedText': (actual: NodeId.localizedText, generated: raw.UA_NS0ID_LOCALIZEDTEXT),
    'structure': (actual: NodeId.structure, generated: raw.UA_NS0ID_STRUCTURE),
    'structureDefinition': (actual: NodeId.structureDefinition, generated: raw.UA_NS0ID_STRUCTUREDEFINITION),
    'structureDefinitionDefaultBinary': (
      actual: NodeId.structureDefinitionDefaultBinary,
      generated: raw.UA_NS0ID_STRUCTUREDEFINITION_ENCODING_DEFAULTBINARY,
    ),
    'enumDefinitionDefaultBinary': (
      actual: NodeId.enumDefinitionDefaultBinary,
      generated: raw.UA_NS0ID_ENUMDEFINITION_ENCODING_DEFAULTBINARY,
    ),
    // Folders.
    'rootFolder': (actual: NodeId.rootFolder, generated: raw.UA_NS0ID_ROOTFOLDER),
    'objectsFolder': (actual: NodeId.objectsFolder, generated: raw.UA_NS0ID_OBJECTSFOLDER),
    'typesFolder': (actual: NodeId.typesFolder, generated: raw.UA_NS0ID_TYPESFOLDER),
    'viewsFolder': (actual: NodeId.viewsFolder, generated: raw.UA_NS0ID_VIEWSFOLDER),
    // The Server object and what hangs under it (#110).
    'server': (actual: NodeId.server, generated: raw.UA_NS0ID_SERVER),
    'serverArray': (actual: NodeId.serverArray, generated: raw.UA_NS0ID_SERVER_SERVERARRAY),
    'namespaceArray': (actual: NodeId.namespaceArray, generated: raw.UA_NS0ID_SERVER_NAMESPACEARRAY),
    'serverStatus': (actual: NodeId.serverStatus, generated: raw.UA_NS0ID_SERVER_SERVERSTATUS),
    'serverStatusStartTime': (
      actual: NodeId.serverStatusStartTime,
      generated: raw.UA_NS0ID_SERVER_SERVERSTATUS_STARTTIME,
    ),
    'serverStatusCurrentTime': (
      actual: NodeId.serverStatusCurrentTime,
      generated: raw.UA_NS0ID_SERVER_SERVERSTATUS_CURRENTTIME,
    ),
    'serverStatusState': (actual: NodeId.serverStatusState, generated: raw.UA_NS0ID_SERVER_SERVERSTATUS_STATE),
    'serverStatusBuildInfo': (
      actual: NodeId.serverStatusBuildInfo,
      generated: raw.UA_NS0ID_SERVER_SERVERSTATUS_BUILDINFO,
    ),
    'serviceLevel': (actual: NodeId.serviceLevel, generated: raw.UA_NS0ID_SERVER_SERVICELEVEL),
    'serverRedundancy': (actual: NodeId.serverRedundancy, generated: raw.UA_NS0ID_SERVER_SERVERREDUNDANCY),
    'redundancySupport': (
      actual: NodeId.redundancySupport,
      generated: raw.UA_NS0ID_SERVER_SERVERREDUNDANCY_REDUNDANCYSUPPORT,
    ),
    'serverUriArray': (actual: NodeId.serverUriArray, generated: raw.UA_NS0ID_SERVER_SERVERREDUNDANCY_SERVERURIARRAY),
    // Reference types.
    'hierarchicalReferences': (actual: NodeId.hierarchicalReferences, generated: raw.UA_NS0ID_HIERARCHICALREFERENCES),
    'hasSubtype': (actual: NodeId.hasSubtype, generated: raw.UA_NS0ID_HASSUBTYPE),
    'organizes': (actual: NodeId.organizes, generated: raw.UA_NS0ID_ORGANIZES),
    'hasComponent': (actual: NodeId.hasComponent, generated: raw.UA_NS0ID_HASCOMPONENT),
    'hasProperty': (actual: NodeId.hasProperty, generated: raw.UA_NS0ID_HASPROPERTY),
    'hasTypeDefinition': (actual: NodeId.hasTypeDefinition, generated: raw.UA_NS0ID_HASTYPEDEFINITION),
    'hasEncoding': (actual: NodeId.hasEncoding, generated: raw.UA_NS0ID_HASENCODING),
    // Type definitions.
    'baseObjectType': (actual: NodeId.baseObjectType, generated: raw.UA_NS0ID_BASEOBJECTTYPE),
    'folderType': (actual: NodeId.folderType, generated: raw.UA_NS0ID_FOLDERTYPE),
    'baseDataVariableType': (actual: NodeId.baseDataVariableType, generated: raw.UA_NS0ID_BASEDATAVARIABLETYPE),
    'propertyType': (actual: NodeId.propertyType, generated: raw.UA_NS0ID_PROPERTYTYPE),
    'dataTypeEncodingType': (actual: NodeId.dataTypeEncodingType, generated: raw.UA_NS0ID_DATATYPEENCODINGTYPE),
  };

  group('NodeId namespace-0 literals match the generated bindings', () {
    expected.forEach((name, pair) {
      test(name, () {
        expect(pair.actual.namespace, 0, reason: '$name must be in namespace 0');
        expect(pair.actual.numeric, pair.generated);
      });
    });
  });

  test('every static NodeId getter on the core is pinned here', () {
    // A static added to node_id_core.dart without a row above would be an
    // unchecked literal. Count them in the source rather than by reflection
    // (dart:mirrors is unavailable under the test runner's AOT/JIT mix).
    final source = File('lib/src/node_id_core.dart').readAsStringSync();
    final statics = RegExp(r'static NodeId get (\w+)').allMatches(source).map((m) => m.group(1)!).toSet();
    expect(statics, expected.keys.toSet());
  });
}
