import 'dart:math';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart';

// End-to-end PubSub round trip: a publisher Server publishes variables over
// UDP multicast on the loopback-reachable group below, and a subscriber Server
// (PubSub subscribers hang off UA_Server, not UA_Client) receives them into
// local target variable nodes. Both event loops are pumped from Dart via the
// runIterate pattern in setupServer.
//
// The test polls with a generous timeout instead of sleeping fixed amounts so
// it is robust to scheduling jitter.
void main() {
  group('PubSub UDP round trip', () {
    late Server publisher;
    late Server subscriber;
    late int udpPort;

    setUp(() {
      final rand = Random();
      publisher = setupServer(rand.nextInt(10000) + 4840);
      subscriber = setupServer(rand.nextInt(10000) + 15000);
      // Non-default multicast group/port to avoid clashes with other OPC UA
      // PubSub participants (default is 224.0.0.22:4840).
      udpPort = rand.nextInt(10000) + 25000;
    });

    tearDown(() {
      subscriber.disableAllPubSubComponents();
      publisher.disableAllPubSubComponents();
      subscriber.shutdown();
      subscriber.delete();
      publisher.shutdown();
      publisher.delete();
    });

    Future<void> waitFor(
      bool Function() condition,
      String what, {
      Duration timeout = const Duration(seconds: 20),
    }) async {
      final deadline = DateTime.now().add(timeout);
      while (!condition()) {
        if (DateTime.now().isAfter(deadline)) {
          fail('Timed out waiting for $what');
        }
        await Future.delayed(Duration(milliseconds: 50));
      }
    }

    test('scalars and an array arrive and update', () async {
      final url = 'opc.udp://224.0.0.42:$udpPort/';

      // ---- Publisher side --------------------------------------------------
      final counterId = NodeId.fromString(1, 'pub.counter');
      final tempId = NodeId.fromString(1, 'pub.temp');
      final arrayId = NodeId.fromString(1, 'pub.array');
      publisher.addVariableNode(counterId, DynamicValue(value: 7, typeId: NodeId.int32, name: 'pub.counter'));
      publisher.addVariableNode(tempId, DynamicValue(value: 21.5, typeId: NodeId.double, name: 'pub.temp'));
      publisher.addVariableNode(
        arrayId,
        DynamicValue.fromList([
          for (final v in [1, 2, 3]) DynamicValue(value: v, typeId: NodeId.int32),
        ], typeId: NodeId.int32)..name = 'pub.array',
      );

      final pubConnection = publisher.addPubSubConnection(
        name: 'Publisher Connection',
        url: url,
        publisherId: PubSubPublisherId.uint16(2234),
      );
      final pds = publisher.addPublishedDataSet(name: 'Roundtrip PDS');
      publisher.addDataSetField(pds, name: 'Counter', publishedVariable: counterId);
      publisher.addDataSetField(pds, name: 'Temperature', publishedVariable: tempId);
      publisher.addDataSetField(pds, name: 'Array', publishedVariable: arrayId);
      final writerGroup = publisher.addWriterGroup(
        pubConnection,
        name: 'Roundtrip WriterGroup',
        writerGroupId: 100,
        publishingInterval: Duration(milliseconds: 50),
      );
      publisher.addDataSetWriter(writerGroup, pds, name: 'Roundtrip Writer', dataSetWriterId: 62541);

      // ---- Subscriber side -------------------------------------------------
      final subConnection = subscriber.addPubSubConnection(name: 'Subscriber Connection', url: url);
      final readerGroup = subscriber.addReaderGroup(subConnection, name: 'Roundtrip ReaderGroup');
      final reader = subscriber.addDataSetReader(
        readerGroup,
        name: 'Roundtrip Reader',
        publisherId: PubSubPublisherId.uint16(2234),
        writerGroupId: 100,
        dataSetWriterId: 62541,
        dataSetName: 'Roundtrip DS',
        fields: [
          DataSetFieldMeta(name: 'Counter', dataType: NodeId.int32),
          DataSetFieldMeta(name: 'Temperature', dataType: NodeId.double),
          DataSetFieldMeta(name: 'Array', dataType: NodeId.int32, valueRank: 1),
        ],
      );

      final counterTarget = NodeId.fromString(1, 'sub.counter');
      final tempTarget = NodeId.fromString(1, 'sub.temp');
      final arrayTarget = NodeId.fromString(1, 'sub.array');
      subscriber.addVariableNode(counterTarget, DynamicValue(value: 0, typeId: NodeId.int32, name: 'sub.counter'));
      subscriber.addVariableNode(tempTarget, DynamicValue(value: 0.0, typeId: NodeId.double, name: 'sub.temp'));
      subscriber.addVariableNode(
        arrayTarget,
        DynamicValue.fromList([
          for (final v in [0, 0, 0]) DynamicValue(value: v, typeId: NodeId.int32),
        ], typeId: NodeId.int32)..name = 'sub.array',
      );
      subscriber.setDataSetReaderTargetVariables(reader, [counterTarget, tempTarget, arrayTarget]);

      // Observe received values through the value-change stream as well.
      final streamed = <int>[];
      final streamSub = subscriber.onValueChanged(counterTarget).listen((v) => streamed.add(v.value as int));

      publisher.enableAllPubSubComponents();
      subscriber.enableAllPubSubComponents();

      int subCounter() {
        final v = subscriber.read(counterTarget);
        return v.isNull ? 0 : v.value as int;
      }

      double subTemp() {
        final v = subscriber.read(tempTarget);
        return v.isNull ? 0.0 : (v.value as num).toDouble();
      }

      List<int> subArray() {
        final v = subscriber.read(arrayTarget);
        if (!v.isArray) return const [];
        return v.asArray.map((e) => e.value as int).toList();
      }

      // Initial values arrive.
      await waitFor(() => subCounter() == 7, 'initial counter value');
      await waitFor(() => (subTemp() - 21.5).abs() < 1e-9, 'initial temperature value');
      await waitFor(() => subArray().join(',') == '1,2,3', 'initial array value');

      // A DataSetReader that has processed a message is operational.
      expect(subscriber.dataSetReaderState(reader), PubSubState.operational);

      // Updates on the publisher's variables propagate.
      publisher.write(counterId, DynamicValue(value: 8, typeId: NodeId.int32));
      publisher.write(tempId, DynamicValue(value: -3.25, typeId: NodeId.double));
      publisher.write(
        arrayId,
        DynamicValue.fromList([
          for (final v in [4, 5, 6]) DynamicValue(value: v, typeId: NodeId.int32),
        ], typeId: NodeId.int32),
      );

      await waitFor(() => subCounter() == 8, 'updated counter value');
      await waitFor(() => (subTemp() + 3.25).abs() < 1e-9, 'updated temperature value');
      await waitFor(() => subArray().join(',') == '4,5,6', 'updated array value');

      // The stream observed the received values (the reader re-writes the
      // target on every keyframe, so both values must have been seen).
      expect(streamed, contains(7));
      expect(streamed, contains(8));
      await streamSub.cancel();
    });
  });
}
