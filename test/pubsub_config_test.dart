import 'dart:math';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart';

// Configuration / smoke tests for the PubSub API: building the publisher and
// subscriber topology on a server succeeds with GOOD status codes (the Dart
// wrappers throw on anything else), components can be enabled/disabled, and
// the value-change stream plumbing works for plain writes.
void main() {
  group('PubSub configuration', () {
    late int port;
    late int udpPort;
    late Server server;

    setUp(() {
      port = Random().nextInt(10000) + 4840;
      // Non-default multicast port so parallel test runs cannot clash.
      udpPort = Random().nextInt(10000) + 20000;
      server = setupServer(port);
    });

    tearDown(() {
      server.shutdown();
      server.delete();
    });

    test('publisher topology: connection, PDS, fields, writer group, writer', () {
      addBasicVariables(server);

      final connection = server.addPubSubConnection(
        name: 'UADP Connection',
        url: 'opc.udp://224.0.0.42:$udpPort/',
        publisherId: PubSubPublisherId.uint16(2234),
      );
      final pds = server.addPublishedDataSet(name: 'Demo PDS');
      server.addDataSetField(pds, name: 'Int', publishedVariable: intNodeId);
      server.addDataSetField(pds, name: 'Double', publishedVariable: doubleNodeId);
      final writerGroup = server.addWriterGroup(
        connection,
        name: 'Demo WriterGroup',
        writerGroupId: 100,
        publishingInterval: Duration(milliseconds: 100),
      );
      final writer = server.addDataSetWriter(writerGroup, pds, name: 'Demo DataSetWriter', dataSetWriterId: 62541);

      // Everything is created disabled.
      expect(server.writerGroupState(writerGroup), PubSubState.disabled);
      expect(server.dataSetWriterState(writer), PubSubState.disabled);

      server.enableAllPubSubComponents();
      // An enabled writer group with an operational connection becomes
      // operational (the publish callback is registered immediately).
      expect(server.writerGroupState(writerGroup), isNot(PubSubState.disabled));
      expect(server.dataSetWriterState(writer), isNot(PubSubState.disabled));

      server.disableAllPubSubComponents();
      expect(server.writerGroupState(writerGroup), PubSubState.disabled);
    });

    test('subscriber topology: reader group, reader, target variables', () {
      final connection = server.addPubSubConnection(
        name: 'UADP Connection',
        url: 'opc.udp://224.0.0.42:$udpPort/',
        // Exercise the string publisher-id marshalling path.
        publisherId: PubSubPublisherId.string('subscriber-connection'),
      );
      final readerGroup = server.addReaderGroup(connection, name: 'ReaderGroup 1');
      final reader = server.addDataSetReader(
        readerGroup,
        name: 'DataSet Reader 1',
        publisherId: PubSubPublisherId.uint16(2234),
        writerGroupId: 100,
        dataSetWriterId: 62541,
        dataSetName: 'DataSet 1',
        fields: [
          DataSetFieldMeta(name: 'Int', dataType: NodeId.int32),
          DataSetFieldMeta(name: 'Double', dataType: NodeId.double),
        ],
      );

      final intTarget = NodeId.fromString(1, 'sub.int');
      final doubleTarget = NodeId.fromString(1, 'sub.double');
      server.addVariableNode(intTarget, DynamicValue(value: 0, typeId: NodeId.int32, name: 'sub.int'));
      server.addVariableNode(doubleTarget, DynamicValue(value: 0.0, typeId: NodeId.double, name: 'sub.double'));
      server.setDataSetReaderTargetVariables(reader, [intTarget, doubleTarget]);

      expect(server.readerGroupState(readerGroup), PubSubState.disabled);
      expect(server.dataSetReaderState(reader), PubSubState.disabled);

      server.enableAllPubSubComponents();
      // No message has been received, so the reader side is enabled but not
      // yet operational.
      expect(server.readerGroupState(readerGroup), isNot(PubSubState.disabled));
      expect(server.dataSetReaderState(reader), isNot(PubSubState.disabled));

      server.disableAllPubSubComponents();
    });

    test('addDataSetReader rejects a non-builtin field data type', () {
      final connection = server.addPubSubConnection(name: 'C', url: 'opc.udp://224.0.0.42:$udpPort/');
      final readerGroup = server.addReaderGroup(connection, name: 'RG');
      expect(
        () => server.addDataSetReader(
          readerGroup,
          name: 'Bad',
          publisherId: PubSubPublisherId.uint16(1),
          writerGroupId: 1,
          dataSetWriterId: 1,
          dataSetName: 'DS',
          fields: [DataSetFieldMeta(name: 'custom', dataType: NodeId.fromString(1, 'my.type'))],
        ),
        throwsA(anything),
      );
    });

    test('onValueChanged emits on server-side writes', () async {
      addBasicVariables(server);
      final events = <DynamicValue>[];
      final sub = server.onValueChanged(intNodeId).listen(events.add);
      // The stream is a broadcast stream: a second listener (via a repeated
      // onValueChanged call) sees the same events.
      final events2 = <DynamicValue>[];
      final sub2 = server.onValueChanged(intNodeId).listen(events2.add);

      server.write(intNodeId, DynamicValue(value: 42, typeId: NodeId.int32));
      server.write(intNodeId, DynamicValue(value: 43, typeId: NodeId.int32));
      // The notification fires synchronously inside the write; give the
      // stream a microtask turn to deliver.
      await Future.delayed(Duration(milliseconds: 10));

      expect(events.map((e) => e.value).toList(), [42, 43]);
      expect(events2.map((e) => e.value).toList(), [42, 43]);
      await sub.cancel();
      await sub2.cancel();
    });

    test('onValueChanged on a missing node throws', () {
      expect(() => server.onValueChanged(NodeId.fromString(1, 'does.not.exist')), throwsA(anything));
    });
  });
}
