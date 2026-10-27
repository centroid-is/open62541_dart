import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'common.dart';

/// The node side of Historical Access: the Historizing attribute, the
/// HistoryRead access bit and the HistoryServerCapabilities a client checks
/// before it sends HistoryRead. Checked through a `Client`.
NodeId ns0(int id) => NodeId.fromNumeric(0, id);

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

  Future<Object?> attribute(NodeId node, AttributeId id) async => (await client.readAttribute({
    node: [id],
  }))[node]!.value;

  Future<int> accessLevel(NodeId node) async => await attribute(node, AttributeId.UA_ATTRIBUTEID_ACCESSLEVEL) as int;
  Future<int> userAccessLevel(NodeId node) async =>
      await attribute(node, AttributeId.UA_ATTRIBUTEID_USERACCESSLEVEL) as int;
  Future<bool> historizing(NodeId node) async => await attribute(node, AttributeId.UA_ATTRIBUTEID_HISTORIZING) as bool;

  final plain = NodeId.fromString(1, 'history.plain');
  final historized = NodeId.fromString(1, 'history.historized');
  final source = NodeId.fromString(1, 'history.source');

  DynamicValue int32(String name) => DynamicValue(value: 1, typeId: NodeId.int32, name: name);

  group('nodes', () {
    test('a variable is not historizing and has no HistoryRead bit by default', () async {
      server.addVariableNode(plain, int32('plain'));
      server.addDataSourceVariableNode(
        source,
        browseName: 'source',
        onRead: () => DynamicValue(value: 1, typeId: NodeId.int32),
      );
      for (final node in [plain, source]) {
        expect(await historizing(node), isFalse);
        expect(await accessLevel(node) & raw.UA_ACCESSLEVELMASK_HISTORYREAD, 0);
        expect(server.readHistorizing(node), isFalse);
      }
    });

    test('historizing: on addVariableNode and addDataSourceVariableNode', () async {
      server.addVariableNode(
        historized,
        int32('historized'),
        accessLevel: const AccessLevelMask(read: true, historyRead: true),
        historizing: true,
      );
      server.addDataSourceVariableNode(
        source,
        browseName: 'source',
        onRead: () => DynamicValue(value: 1, typeId: NodeId.int32),
        accessLevel: const AccessLevelMask(read: true, historyRead: true),
        historizing: true,
      );
      for (final node in [historized, source]) {
        expect(await historizing(node), isTrue);
        expect(await accessLevel(node), raw.UA_ACCESSLEVELMASK_READ | raw.UA_ACCESSLEVELMASK_HISTORYREAD);
        expect(await userAccessLevel(node) & raw.UA_ACCESSLEVELMASK_HISTORYREAD, raw.UA_ACCESSLEVELMASK_HISTORYREAD);
        expect(server.readHistorizing(node), isTrue);
      }
    });

    test('setHistorizing and setAccessLevel change an existing node', () async {
      server.addVariableNode(plain, int32('plain'));
      server.setHistorizing(plain, true);
      server.setAccessLevel(plain, const AccessLevelMask(read: true, write: true, historyRead: true));
      expect(await historizing(plain), isTrue);
      expect(
        await accessLevel(plain),
        raw.UA_ACCESSLEVELMASK_READ | raw.UA_ACCESSLEVELMASK_WRITE | raw.UA_ACCESSLEVELMASK_HISTORYREAD,
      );
      expect(server.readAccessLevel(plain), const AccessLevelMask(read: true, write: true, historyRead: true));

      server.setHistorizing(plain, false);
      server.setAccessLevel(plain, const AccessLevelMask(read: true));
      expect(await historizing(plain), isFalse);
      expect(await accessLevel(plain), raw.UA_ACCESSLEVELMASK_READ);
      expect(server.readHistorizing(plain), isFalse);
    });

    test('the setters and readers throw the native status for a missing node', () {
      final missing = NodeId.fromString(1, 'history.missing');
      final unknown = isA<UaStatusException>().having(
        (e) => e.statusCode,
        'statusCode',
        raw.UA_STATUSCODE_BADNODEIDUNKNOWN,
      );
      expect(() => server.setHistorizing(missing, true), throwsA(unknown));
      expect(() => server.readHistorizing(missing), throwsA(unknown));
      expect(() => server.setAccessLevel(missing, const AccessLevelMask(read: true)), throwsA(unknown));
      expect(() => server.readAccessLevel(missing), throwsA(unknown));
    });

    test('AccessLevelMask.fromValue inverts value', () {
      for (var v = 0; v < 0x80; v++) {
        expect(AccessLevelMask.fromValue(v).value, v);
      }
      expect(AccessLevelMask.fromValue(0x05), const AccessLevelMask(read: true, historyRead: true));
    });
  });

  group('HistoryServerCapabilities', () {
    final accessHistoryData = ns0(raw.UA_NS0ID_HISTORYSERVERCAPABILITIES_ACCESSHISTORYDATACAPABILITY);
    final maxReturnDataValues = ns0(raw.UA_NS0ID_HISTORYSERVERCAPABILITIES_MAXRETURNDATAVALUES);
    final maxContinuationPoints = ns0(raw.UA_NS0ID_SERVER_SERVERCAPABILITIES_MAXHISTORYCONTINUATIONPOINTS);
    final flags = {
      'accessHistoryEvents': raw.UA_NS0ID_HISTORYSERVERCAPABILITIES_ACCESSHISTORYEVENTSCAPABILITY,
      'insertData': raw.UA_NS0ID_HISTORYSERVERCAPABILITIES_INSERTDATACAPABILITY,
      'replaceData': raw.UA_NS0ID_HISTORYSERVERCAPABILITIES_REPLACEDATACAPABILITY,
      'updateData': raw.UA_NS0ID_HISTORYSERVERCAPABILITIES_UPDATEDATACAPABILITY,
      'deleteRaw': raw.UA_NS0ID_HISTORYSERVERCAPABILITIES_DELETERAWCAPABILITY,
      'deleteAtTime': raw.UA_NS0ID_HISTORYSERVERCAPABILITIES_DELETEATTIMECAPABILITY,
      'insertAnnotation': raw.UA_NS0ID_HISTORYSERVERCAPABILITIES_INSERTANNOTATIONCAPABILITY,
      'insertEvent': raw.UA_NS0ID_HISTORYSERVERCAPABILITIES_INSERTEVENTCAPABILITY,
      'replaceEvent': raw.UA_NS0ID_HISTORYSERVERCAPABILITIES_REPLACEEVENTCAPABILITY,
      'updateEvent': raw.UA_NS0ID_HISTORYSERVERCAPABILITIES_UPDATEEVENTCAPABILITY,
      'deleteEvent': raw.UA_NS0ID_HISTORYSERVERCAPABILITIES_DELETEEVENTCAPABILITY,
    };

    Future<Object?> value(NodeId node) async => (await client.read(node)).value;

    test('a server that never sets them advertises no history', () async {
      expect(await value(accessHistoryData), isFalse);
      expect(await value(maxReturnDataValues), 0);
      expect(await value(maxContinuationPoints), 0);
      for (final id in flags.values) {
        expect(await value(ns0(id)), isFalse, reason: 'i=$id');
      }
    });

    test('setHistoryServerCapabilities writes the nodes a client reads', () async {
      server.setHistoryServerCapabilities(maxReturnDataValues: 1000, maxHistoryContinuationPoints: 50);
      expect(await value(accessHistoryData), isTrue);
      expect(await value(maxReturnDataValues), 1000);
      expect(await value(maxContinuationPoints), 50);
      expect((await client.read(maxContinuationPoints)).typeId, NodeId.uint16);
      expect(await value(ns0(raw.UA_NS0ID_HISTORYSERVERCAPABILITIES_MAXRETURNEVENTVALUES)), 0);
      for (final id in flags.values) {
        expect(await value(ns0(id)), isFalse, reason: 'i=$id');
      }
    });

    test('every flag and limit lands on its own node, and a later call resets what it leaves out', () async {
      server.setHistoryServerCapabilities(
        accessHistoryData: false,
        accessHistoryEvents: true,
        maxReturnEventValues: 7,
        insertData: true,
        replaceData: true,
        updateData: true,
        deleteRaw: true,
        deleteAtTime: true,
        insertAnnotation: true,
        insertEvent: true,
        replaceEvent: true,
        updateEvent: true,
        deleteEvent: true,
      );
      expect(await value(accessHistoryData), isFalse);
      expect(await value(ns0(raw.UA_NS0ID_HISTORYSERVERCAPABILITIES_MAXRETURNEVENTVALUES)), 7);
      for (final id in flags.values) {
        expect(await value(ns0(id)), isTrue, reason: 'i=$id');
      }

      server.setHistoryServerCapabilities();
      expect(await value(accessHistoryData), isTrue);
      expect(await value(ns0(raw.UA_NS0ID_HISTORYSERVERCAPABILITIES_MAXRETURNEVENTVALUES)), 0);
      for (final id in flags.values) {
        expect(await value(ns0(id)), isFalse, reason: 'i=$id');
      }
    });

    test('a client finds them by browsing HistoryServerCapabilities', () async {
      final refs = await client.browse(ns0(raw.UA_NS0ID_HISTORYSERVERCAPABILITIES));
      final ids = refs.map((r) => r.nodeId).toSet();
      expect(ids, containsAll([accessHistoryData, maxReturnDataValues, ...flags.values.map(ns0)]));
    });
  });
}
