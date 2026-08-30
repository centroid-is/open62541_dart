import 'dart:async';
import 'dart:math';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart';

void main() {
  group('Data-source reads carry status + source timestamp', () {
    late int port;
    late Server server;
    late Client client;

    setUp(() async {
      port = Random().nextInt(10000) + 4840;
      server = setupServer(port);
      client = await setupClient(port);
    });

    tearDown(() async {
      await client.delete();
      server.shutdown();
      server.delete();
    });

    test('client observes Bad_NoCommunication + fixed sourceTimestamp, then Good', () async {
      final nodeId = NodeId.fromString(1, 'datasource.quality');
      final fixedTs = DateTime.utc(2024, 5, 17, 12, 34, 56, 789);
      var status = UA_STATUSCODE_BADNOCOMMUNICATION; // 0x80310000
      expect(UA_STATUSCODE_BADNOCOMMUNICATION, 0x80310000);

      server.addDataSourceVariableNode(
        nodeId,
        browseName: 'Quality',
        typeId: NodeId.int32,
        onReadValue: () => DataSourceValue(
          value: DynamicValue(name: 'Quality', value: 42, typeId: NodeId.int32),
          statusCode: status,
          sourceTimestamp: fixedTs,
        ),
      );

      // PLC-down case: the value is still served (last-known), but the status
      // is exactly Bad_NoCommunication and the source timestamp is the fixed
      // one supplied by the data source (NOT server-assigned "now").
      final bad = await client.readValue(nodeId);
      expect(bad.statusCode, UA_STATUSCODE_BADNOCOMMUNICATION);
      expect(bad.isBad, isTrue);
      expect(bad.isGood, isFalse);
      expect(bad.value.value, 42);
      expect(bad.sourceTimestamp, fixedTs);
      expect(bad.serverTimestamp, isNotNull);

      // Flipping the source back to Good is observed too.
      status = UA_STATUSCODE_GOOD;
      final good = await client.readValue(nodeId);
      expect(good.statusCode, UA_STATUSCODE_GOOD);
      expect(good.isGood, isTrue);
      expect(good.value.value, 42);
      expect(good.sourceTimestamp, fixedTs);
    });

    test('plain read() still throws on a non-Good status (behavior unchanged)', () async {
      final nodeId = NodeId.fromString(1, 'datasource.bad_for_read');
      server.addDataSourceVariableNode(
        nodeId,
        browseName: 'BadForRead',
        typeId: NodeId.int32,
        onReadValue: () => DataSourceValue(
          value: DynamicValue(name: 'BadForRead', value: 1, typeId: NodeId.int32),
          statusCode: UA_STATUSCODE_BADNOCOMMUNICATION,
        ),
      );
      await expectLater(client.read(nodeId), throwsA(anything));
    });

    test('onRead without status keeps working and reads Good (back-compat)', () async {
      final nodeId = NodeId.fromString(1, 'datasource.plain');
      server.addDataSourceVariableNode(
        nodeId,
        browseName: 'Plain',
        typeId: NodeId.double,
        onRead: () => DynamicValue(name: 'Plain', value: 2.5, typeId: NodeId.double),
      );
      final dv = await client.readValue(nodeId);
      expect(dv.statusCode, UA_STATUSCODE_GOOD);
      expect(dv.isGood, isTrue);
      expect((dv.value.value as num).toDouble(), 2.5);
      // No source timestamp supplied by the data source: open62541 stamps the
      // current time, so the client still receives one.
      expect(dv.sourceTimestamp, isNotNull);
    });

    test('exactly one of onRead / onReadValue must be provided', () {
      final nodeId = NodeId.fromString(1, 'datasource.invalid');
      expect(() => server.addDataSourceVariableNode(nodeId, browseName: 'X'), throwsArgumentError);
      expect(
        () => server.addDataSourceVariableNode(
          nodeId,
          browseName: 'X',
          onRead: () => DynamicValue(value: 1, typeId: NodeId.int32),
          onReadValue: () => DataSourceValue(value: DynamicValue(value: 1, typeId: NodeId.int32)),
        ),
        throwsArgumentError,
      );
    });

    test('monitored item: a non-Good notification surfaces as a stream error carrying the status', () async {
      final nodeId = NodeId.fromString(1, 'datasource.monitored');
      var status = UA_STATUSCODE_BADNOCOMMUNICATION;

      server.addDataSourceVariableNode(
        nodeId,
        browseName: 'Monitored',
        typeId: NodeId.int32,
        onReadValue: () => DataSourceValue(
          value: DynamicValue(name: 'Monitored', value: 42, typeId: NodeId.int32),
          statusCode: status,
        ),
      );

      final subId = await client.subscriptionCreate();
      final events = StreamController<Object>();
      final sub = client
          .monitoredItems({
            nodeId: [AttributeId.UA_ATTRIBUTEID_VALUE],
          }, subId)
          .listen((data) => events.add(data), onError: (Object e) => events.add(e));

      // While the source reports Bad, the subscription surfaces an ERROR event
      // (the value/timestamp of the Bad notification are not delivered on the
      // data stream) whose text carries the decoded status name.
      final iterator = StreamIterator(events.stream);
      expect(await iterator.moveNext().timeout(const Duration(seconds: 10)), isTrue);
      final first = iterator.current;
      expect(first, isNot(isA<Map<NodeId, DynamicValue>>()));
      expect(first.toString(), contains('BadNoCommunication'));

      // Flip to Good: the next sample is delivered as a data event.
      status = UA_STATUSCODE_GOOD;
      Object? dataEvent;
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (DateTime.now().isBefore(deadline)) {
        if (!await iterator.moveNext().timeout(const Duration(seconds: 10))) break;
        if (iterator.current is Map<NodeId, DynamicValue>) {
          dataEvent = iterator.current;
          break;
        }
      }
      expect(dataEvent, isNotNull);
      expect((dataEvent as Map<NodeId, DynamicValue>)[nodeId]!.value, 42);

      await iterator.cancel();
      await sub.cancel();
      await events.close();
    });
  });
}
