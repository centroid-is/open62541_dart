// Regression test: a value whose DataType is a structure the client's
// open62541 knows (every NS0 DataType in `UA_TYPES`) arrives decoded into the
// native struct, not as an encoded ExtensionObject. The variant's `type` is
// `&UA_TYPES[UA_TYPES_SERVERSTATUSDATATYPE]` (typeKind STRUCTURE) and `data`
// points at a `UA_ServerStatusDataType` in memory.
//
// Symptom on main
//   `variantToValue` only knew scalar payloads and ExtensionObject wire
//   bodies, so it read the native struct memory as an ExtensionObject header
//   and failed with "Unknown value for UA_ExtensionObjectEncoding: 5" (the
//   first bytes of `startTime`, a DateTime). Reachable from read, readValue,
//   readAttribute, both monitor flavours, Client.call outputs, and
//   Server.read of the server's own ServerStatus.
//
// Fixture
//   The in-process Server's `Server/ServerStatus` (i=2256, a
//   ServerStatusDataType) and `ServerStatus/BuildInfo` (i=2260, a BuildInfo).
//   `ServerStatus/State` (i=2259) is an enum scalar that already decoded on
//   main and is kept as a control. Field names are the `memberName` of each
//   `UA_DataTypeMember`, the same names the DataTypeDefinition of the type
//   carries ("StartTime", not the C field `startTime`).

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'common.dart';

final serverStatusId = NodeId.fromNumeric(0, raw.UA_NS0ID_SERVER_SERVERSTATUS);
final buildInfoId = NodeId.fromNumeric(0, raw.UA_NS0ID_SERVER_SERVERSTATUS_BUILDINFO);
final stateId = NodeId.fromNumeric(0, raw.UA_NS0ID_SERVER_SERVERSTATUS_STATE);
final serverStatusTypeId = NodeId.fromNumeric(0, raw.UA_NS0ID_SERVERSTATUSDATATYPE);
final buildInfoTypeId = NodeId.fromNumeric(0, raw.UA_NS0ID_BUILDINFO);

const serverStatusFields = ['StartTime', 'CurrentTime', 'State', 'BuildInfo', 'SecondsTillShutdown', 'ShutdownReason'];
const buildInfoFields = [
  'ProductUri',
  'ManufacturerName',
  'ProductName',
  'SoftwareVersion',
  'BuildNumber',
  'BuildDate',
];

/// The checks every decoded BuildInfo must pass, wherever it came from.
void expectBuildInfo(DynamicValue buildInfo) {
  expect(buildInfo.isObject, isTrue, reason: 'BuildInfo should be an object, got ${buildInfo.value}');
  expect(buildInfo.asObject.keys.toList(), buildInfoFields);
  expect(buildInfo.typeId, buildInfoTypeId);
  for (final field in buildInfoFields.take(5)) {
    expect(buildInfo[field].isString, isTrue, reason: '$field should be a string');
    expect(buildInfo[field].typeId, NodeId.uastring);
    expect(buildInfo[field].name, field);
  }
  // open62541's defaults: "http://open62541.org", "open62541", the version.
  expect(buildInfo['ProductUri'].asString, isNotEmpty);
  expect(buildInfo['ManufacturerName'].asString, 'open62541');
  expect(buildInfo['SoftwareVersion'].asString, contains(raw.UA_OPEN62541_VER_MAJOR.toString()));
  expect(buildInfo['BuildDate'].value, isA<DateTime>());
  expect(buildInfo['BuildDate'].typeId, NodeId.datetime);
}

/// The checks every decoded ServerStatus must pass, wherever it came from.
void expectServerStatus(DynamicValue status) {
  expect(status.isObject, isTrue, reason: 'ServerStatus should be an object, got ${status.value}');
  expect(status.asObject.keys.toList(), serverStatusFields);
  expect(status.typeId, serverStatusTypeId);
  expect(status['StartTime'].value, isA<DateTime>());
  expect(status['CurrentTime'].value, isA<DateTime>());
  final now = DateTime.now().toUtc();
  expect(status['StartTime'].asDateTime!.isBefore(now.add(Duration(seconds: 5))), isTrue);
  expect(status['CurrentTime'].asDateTime!.difference(now).abs(), lessThan(Duration(minutes: 1)));
  // State is an enum: an Int32 with the native enum's fields (0 = Running).
  final state = status['State'];
  expect(state.isInteger, isTrue);
  expect(state.asInt, 0);
  expect(state.typeId, NodeId.int32);
  expect(state.enumFields, isNotNull);
  expect(state.enumFields![0]!.name, 'Running');
  expect(state.enumFields![7]!.name, 'Unknown');
  expect(state.name, 'State');
  expectBuildInfo(status['BuildInfo']);
  expect(status['BuildInfo'].name, 'BuildInfo');
  expect(status['SecondsTillShutdown'].asInt, 0);
  expect(status['SecondsTillShutdown'].typeId, NodeId.uint32);
  // A null LocalizedText: both strings empty.
  expect(status['ShutdownReason'].value, isA<LocalizedText>());
  expect((status['ShutdownReason'].value as LocalizedText).value, '');
  expect(status['ShutdownReason'].typeId, NodeId.localizedText);
}

void main() {
  for (final clientType in clientTypes) {
    group('$clientType client: known NS0 structure', () {
      late Server server;
      late ClientApi client;

      setUp(() async {
        server = setupServer();
        client = await setupClientOfType(clientType, 'opc.tcp://127.0.0.1:${server.port}');
      });

      tearDown(() async {
        await client.delete();
        server.shutdown();
        server.delete();
      });

      test('read ServerStatus (i=2256) is an object with the six members', () async {
        expectServerStatus(await client.read(serverStatusId));
      });

      test('readValue ServerStatus carries the struct as its value', () async {
        final dataValue = await client.readValue(serverStatusId);
        expect(dataValue.isGood, isTrue);
        expectServerStatus(dataValue.value);
      });

      test('readAttribute Value of ServerStatus is the struct', () async {
        final read = await client.readAttribute({
          serverStatusId: [AttributeId.UA_ATTRIBUTEID_VALUE, AttributeId.UA_ATTRIBUTEID_DATATYPE],
        });
        expectServerStatus(read[serverStatusId]!);
      });

      test('read BuildInfo (i=2260) is an object with the six members', () async {
        expectBuildInfo(await client.read(buildInfoId));
      });

      test('readValue BuildInfo', () async {
        expectBuildInfo((await client.readValue(buildInfoId)).value);
      });

      test('ServerStatus/State (i=2259) enum scalar still decodes (control)', () async {
        final state = await client.read(stateId);
        expect(state.isInteger, isTrue);
        expect(state.asInt, 0);
        expect(state.enumFields, isNotNull);
        expect(state.enumFields![0]!.name, 'Running');
      });

      test('a second read is served the same way (no stale schema state)', () async {
        expectServerStatus(await client.read(serverStatusId));
        expectBuildInfo(await client.read(buildInfoId));
        expectServerStatus(await client.read(serverStatusId));
      });

      test('monitor delivers the struct', () async {
        final subId = await client.subscriptionCreate();
        final first = await client
            .monitor(serverStatusId, subId, samplingInterval: Duration(milliseconds: 50))
            .first
            .timeout(Duration(seconds: 10));
        expectServerStatus(first);
      });

      test('monitorDataValue delivers the struct', () async {
        final subId = await client.subscriptionCreate();
        final first = await (client as DataValueMonitoringApi)
            .monitorDataValue(serverStatusId, subId, samplingInterval: Duration(milliseconds: 50))
            .first
            .timeout(Duration(seconds: 10));
        expect(first.isGood, isTrue);
        expectServerStatus(first.value);
      });

      test('monitoredItems delivers the struct keyed by node', () async {
        final subId = await client.subscriptionCreate();
        final first = await client
            .monitoredItems(
              {
                serverStatusId: [AttributeId.UA_ATTRIBUTEID_VALUE],
                buildInfoId: [AttributeId.UA_ATTRIBUTEID_VALUE],
              },
              subId,
              samplingInterval: Duration(milliseconds: 50),
            )
            .firstWhere((event) => event.containsKey(serverStatusId) && event.containsKey(buildInfoId))
            .timeout(Duration(seconds: 10));
        expectServerStatus(first[serverStatusId]!);
        expectBuildInfo(first[buildInfoId]!);
      });
    });
  }

  group('Server.read of its own NS0 structure', () {
    late Server server;

    setUp(() {
      server = setupServer();
    });

    tearDown(() {
      server.shutdown();
      server.delete();
    });

    test('ServerStatus (i=2256)', () {
      expectServerStatus(server.read(serverStatusId));
    });

    test('BuildInfo (i=2260)', () {
      expectBuildInfo(server.read(buildInfoId));
    });
  });
}
