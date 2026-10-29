import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/common.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'common.dart';
import 'history_memory_backend.dart';
import 'history_raw_client.dart';

/// `Server.setHistoryBackend`: HistoryRead served from a Dart
/// [HistoryBackend], checked through a raw HistoryRead client.

final temperature = NodeId.fromString(1, 'history.temperature');
final pressure = NodeId.fromString(1, 'history.pressure');
final plain = NodeId.fromString(1, 'history.plain');
final missing = NodeId.fromString(1, 'history.missing');

RawHistoryNode node(NodeId id, [Uint8List? cp]) => (nodeId: id, continuationPoint: cp);

void main() {
  late Server server;
  late RawHistoryClient client;
  late MemoryBackend backend;
  var serverDeleted = false;

  setUp(() async {
    serverDeleted = false;
    server = setupServer();
    for (final id in [temperature, pressure]) {
      server.addVariableNode(
        id,
        DynamicValue(value: 0, typeId: NodeId.int32, name: id.string),
        accessLevel: const AccessLevelMask(read: true, historyRead: true),
        historizing: true,
      );
    }
    server.addVariableNode(plain, DynamicValue(value: 0, typeId: NodeId.int32, name: 'plain'));
    backend = MemoryBackend({temperature: samples(5), pressure: samples(3, base: 100)});
    server.setHistoryBackend(backend);
    client = await RawHistoryClient.connect(server.port);
  });

  // The server goes first: deleting a raw client disconnects it with a
  // blocking CloseSession, which a server pumped on this isolate cannot
  // answer.
  tearDown(() {
    if (!serverDeleted) {
      server.shutdown();
      server.delete();
    }
    client.delete();
  });

  List<Object?> valuesOf(RawHistoryResult r) => r.values.map((v) => v.value).toList();

  test('a server without a backend answers Bad_NotSupported', () async {
    server.setHistoryBackend(null);
    final response = await client.read([node(temperature)]);
    expect(response.serviceResult, raw.UA_STATUSCODE_BADNOTSUPPORTED);
    expect(backend.calls, isEmpty);
  });

  test('ReadRaw returns the values with their status and both timestamps', () async {
    final response = await client.read([node(temperature), node(pressure)]);
    expect(response.serviceResult, raw.UA_STATUSCODE_GOOD);
    expect(backend.calls, hasLength(1), reason: 'one backend call per request');
    expect(backend.calls.single.map((r) => r.nodeId), [temperature, pressure]);
    final temp = response.results[0];
    expect(temp.statusCode, raw.UA_STATUSCODE_GOOD);
    expect(valuesOf(temp), [0, 1, 2, 3, 4]);
    expect(temp.continuationPoint, isNull);
    final first = temp.values.first;
    expect(first.flags, 0x01 | 0x04 | 0x08, reason: 'hasValue, hasSourceTimestamp, hasServerTimestamp; no status');
    expect(uaDateTimeToDateTime(first.sourceTimestamp), t0);
    expect(uaDateTimeToDateTime(first.serverTimestamp), t0.add(const Duration(milliseconds: 1)));
    expect(valuesOf(response.results[1]), [100, 101, 102]);
  });

  test('the request reaches the backend as asked, with the session', () async {
    await client.read(
      [node(temperature)],
      details: readRawDetails(
        startTime: dateTimeToUaDateTime(t0.add(const Duration(seconds: 1))),
        endTime: dateTimeToUaDateTime(t0.add(const Duration(seconds: 3))),
        numValuesPerNode: 7,
        returnBounds: true,
      ),
      timestampsToReturn: raw.UA_TimestampsToReturn.UA_TIMESTAMPSTORETURN_SOURCE,
    );
    final request = backend.calls.single.single;
    expect(request.nodeId, temperature);
    expect(request.start, t0.add(const Duration(seconds: 1)));
    expect(request.end, t0.add(const Duration(seconds: 3)));
    expect(request.numValuesPerNode, 7);
    expect(request.returnBounds, isTrue);
    expect(request.timestampsToReturn, TimestampsToReturn.UA_TIMESTAMPSTORETURN_SOURCE);
    expect(request.continuationPoint, isNull);
    expect(request.indexRange, isNull);
    expect(request.session.sessionId, isNot(NodeId.nullId));
    expect(request.session.identity, const AnonymousSessionIdentity());
  });

  test('an unspecified start or end is null', () async {
    await client.read([node(temperature)]);
    expect(backend.calls.single.single.start, isNull);
    expect(backend.calls.single.single.end, isNull);
  });

  test('timestampsToReturn decides which timestamps are sent', () async {
    final source = await client.read([
      node(temperature),
    ], timestampsToReturn: raw.UA_TimestampsToReturn.UA_TIMESTAMPSTORETURN_SOURCE);
    expect(source.results.single.values.first.flags, 0x01 | 0x04);
    final serverOnly = await client.read([
      node(temperature),
    ], timestampsToReturn: raw.UA_TimestampsToReturn.UA_TIMESTAMPSTORETURN_SERVER);
    expect(serverOnly.results.single.values.first.flags, 0x01 | 0x08);
  });

  test('timestampsToReturn Neither is refused before the backend', () async {
    final response = await client.read([
      node(temperature),
    ], timestampsToReturn: raw.UA_TimestampsToReturn.UA_TIMESTAMPSTORETURN_NEITHER);
    expect(response.serviceResult, raw.UA_STATUSCODE_BADTIMESTAMPSTORETURNINVALID);
    expect(backend.calls, isEmpty);
  });

  test('a value with a Bad status and no value carries only the status', () async {
    backend.series[temperature] = [
      DataValue(value: DynamicValue(), statusCode: raw.UA_STATUSCODE_BADNOCOMMUNICATION, sourceTimestamp: t0),
    ];
    final value = (await client.read([node(temperature)])).results.single.values.single;
    expect(value.flags, 0x02 | 0x04);
    expect(value.status, raw.UA_STATUSCODE_BADNOCOMMUNICATION);
    expect(value.value, isNull);
  });

  test('pages follow the continuation point until the node is done', () async {
    final pages = <List<Object?>>[];
    Uint8List? cp;
    do {
      final response = await client.read([node(temperature, cp)], details: readRawDetails(numValuesPerNode: 2));
      final result = response.results.single;
      expect(result.statusCode, raw.UA_STATUSCODE_GOOD);
      pages.add(valuesOf(result));
      cp = result.continuationPoint;
    } while (cp != null);
    expect(pages, [
      [0, 1],
      [2, 3],
      [4],
    ]);
    expect(backend.calls.map((c) => c.single.continuationPoint).map((cp) => cp == null ? null : offsetOf(cp)), [
      null,
      2,
      4,
    ]);
  });

  test('an empty page is an empty array, not a null one', () async {
    backend.series[temperature] = [];
    final result = (await client.read([node(temperature)])).results.single;
    expect(result.statusCode, raw.UA_STATUSCODE_GOODNODATA);
    expect(result.values, isEmpty);
    expect(result.dataValuesNull, isFalse);
  });

  test('maxReturnDataValues caps numValuesPerNode', () async {
    server.setHistoryBackend(backend, maxReturnDataValues: 3);
    for (final (asked, expected) in [(0, 3), (10, 3), (2, 2)]) {
      backend.calls.clear();
      final response = await client.read([node(temperature)], details: readRawDetails(numValuesPerNode: asked));
      expect(backend.calls.single.single.numValuesPerNode, expected, reason: 'asked $asked');
      expect(response.results.single.values, hasLength(expected));
      expect(response.results.single.continuationPoint, isNotNull);
    }
    expect(() => server.setHistoryBackend(backend, maxReturnDataValues: -1), throwsArgumentError);
  });

  test('releaseContinuationPoints hands the points to the backend and answers at once', () async {
    final first = await client.read([node(temperature), node(pressure)], details: readRawDetails(numValuesPerNode: 1));
    final cps = first.results.map((r) => r.continuationPoint!).toList();
    backend.calls.clear();
    backend.gate = Completer<void>();

    final response = await client.read([
      node(temperature, cps[0]),
      node(pressure, cps[1]),
      node(plain),
    ], releaseContinuationPoints: true);
    expect(response.serviceResult, raw.UA_STATUSCODE_GOOD);
    expect(response.results.map((r) => r.statusCode), [
      raw.UA_STATUSCODE_GOOD,
      raw.UA_STATUSCODE_GOOD,
      raw.UA_STATUSCODE_BADHISTORYOPERATIONINVALID,
    ]);
    expect(response.results[0].values, isEmpty);
    expect(response.results[0].continuationPoint, isNull);
    expect(backend.calls, isEmpty, reason: 'a release reads nothing');
    expect(backend.released, cps);
  });

  test('a backend that throws on release still releases', () async {
    backend.releaseError = StateError('gone');
    final response = await client.read([node(temperature, cpFor(1))], releaseContinuationPoints: true);
    expect(response.results.single.statusCode, raw.UA_STATUSCODE_GOOD);
    expect(backend.released.map(offsetOf), [1]);
  });

  test('a release without continuation points does not call the backend', () async {
    final response = await client.read([node(temperature)], releaseContinuationPoints: true);
    expect(response.results.single.statusCode, raw.UA_STATUSCODE_GOOD);
    expect(backend.released, isEmpty);
    expect(backend.calls, isEmpty);
  });

  test('the IndexRange reaches the backend', () async {
    await client.read([node(temperature)], indexRange: '1:2');
    expect(backend.calls.single.single.indexRange, '1:2');
  });

  test('the server answers unknown and non-historizing nodes itself', () async {
    final response = await client.read([node(missing), node(temperature), node(plain)]);
    expect(response.results.map((r) => r.statusCode), [
      raw.UA_STATUSCODE_BADNODEIDUNKNOWN,
      raw.UA_STATUSCODE_GOOD,
      raw.UA_STATUSCODE_BADHISTORYOPERATIONINVALID,
    ]);
    expect(backend.calls.single.map((r) => r.nodeId), [temperature]);
    expect(valuesOf(response.results[1]), [0, 1, 2, 3, 4]);
  });

  test('a request with no historizing node never reaches the backend', () async {
    final response = await client.read([node(plain), node(missing)]);
    expect(response.results.map((r) => r.statusCode), [
      raw.UA_STATUSCODE_BADHISTORYOPERATIONINVALID,
      raw.UA_STATUSCODE_BADNODEIDUNKNOWN,
    ]);
    expect(backend.calls, isEmpty);
  });

  test('setHistorizing and deleteNode keep the historizing nodes in step', () async {
    server.setHistorizing(plain, true);
    backend.series[plain] = samples(1, base: 9);
    expect(valuesOf((await client.read([node(plain)])).results.single), [9]);

    server.setHistorizing(plain, false);
    expect((await client.read([node(plain)])).results.single.statusCode, raw.UA_STATUSCODE_BADHISTORYOPERATIONINVALID);

    server.deleteNode(temperature);
    expect((await client.read([node(temperature)])).results.single.statusCode, raw.UA_STATUSCODE_BADNODEIDUNKNOWN);
  });

  test('a historizing data-source node reads', () async {
    final source = NodeId.fromString(1, 'history.source');
    server.addDataSourceVariableNode(
      source,
      browseName: 'source',
      onRead: () => DynamicValue(value: 1, typeId: NodeId.int32),
      historizing: true,
    );
    backend.series[source] = samples(2, base: 50);
    expect(valuesOf((await client.read([node(source)])).results.single), [50, 51]);
  });

  test('the answer waits for the backend without blocking the server', () async {
    backend.gate = Completer<void>();
    var answered = false;
    final pending = client.read([node(temperature)]).whenComplete(() => answered = true);
    await Future.delayed(const Duration(milliseconds: 300));
    expect(answered, isFalse);
    // The server keeps serving other requests meanwhile.
    expect((await client.read([node(missing)])).results.single.statusCode, raw.UA_STATUSCODE_BADNODEIDUNKNOWN);
    backend.gate!.complete();
    expect(valuesOf((await pending).results.single), [0, 1, 2, 3, 4]);
  });

  group('a failing backend', () {
    test('a UaStatusException answers every node with its code', () async {
      backend.error = const UaStatusException(raw.UA_STATUSCODE_BADCONTINUATIONPOINTINVALID);
      final response = await client.read([node(temperature), node(missing), node(pressure)]);
      expect(response.results.map((r) => r.statusCode), [
        raw.UA_STATUSCODE_BADCONTINUATIONPOINTINVALID,
        raw.UA_STATUSCODE_BADNODEIDUNKNOWN,
        raw.UA_STATUSCODE_BADCONTINUATIONPOINTINVALID,
      ]);
    });

    test('any other error answers Bad_InternalError', () async {
      backend.error = StateError('database down');
      final response = await client.read([node(temperature)]);
      expect(response.results.single.statusCode, raw.UA_STATUSCODE_BADINTERNALERROR);
    });

    test('a synchronous throw is answered the same way', () async {
      backend.syncError = const UaStatusException(raw.UA_STATUSCODE_BADOUTOFMEMORY);
      expect((await client.read([node(temperature)])).results.single.statusCode, raw.UA_STATUSCODE_BADOUTOFMEMORY);
      backend.syncError = ArgumentError('bug');
      expect((await client.read([node(temperature)])).results.single.statusCode, raw.UA_STATUSCODE_BADINTERNALERROR);
    });

    test('a result count that does not match the nodes is Bad_InternalError', () async {
      backend.resultCount = 1;
      final response = await client.read([node(temperature), node(pressure)]);
      expect(response.results.map((r) => r.statusCode), [
        raw.UA_STATUSCODE_BADINTERNALERROR,
        raw.UA_STATUSCODE_BADINTERNALERROR,
      ]);
    });

    test('a value that cannot be encoded fails its node only', () async {
      backend.series[temperature] = [
        DataValue(
          value: DynamicValue(value: 'x'),
          statusCode: raw.UA_STATUSCODE_GOOD,
        ),
      ];
      final response = await client.read([node(temperature), node(pressure)]);
      expect(response.results[0].statusCode, raw.UA_STATUSCODE_BADINTERNALERROR);
      expect(response.results[0].values, isEmpty);
      expect(valuesOf(response.results[1]), [100, 101, 102]);
    });
  });

  test('a backend slower than asyncOperationTimeout: Bad_Timeout, the late answer is dropped', () async {
    server.asyncOperationTimeout = const Duration(milliseconds: 300);
    backend.gate = Completer<void>();
    final response = await client.read([node(temperature), node(pressure)]);
    expect(response.results.map((r) => r.statusCode), [raw.UA_STATUSCODE_BADTIMEOUT, raw.UA_STATUSCODE_BADTIMEOUT]);
    backend.gate!.complete();
    await Future.delayed(const Duration(milliseconds: 200));
    // The server still answers.
    backend.gate = null;
    expect(valuesOf((await client.read([node(pressure)])).results.single), [100, 101, 102]);
  });

  test('deleting the server with a read in flight drops the answer', () async {
    backend.gate = Completer<void>();
    final pending = client.read([node(temperature)]);
    await Future.delayed(const Duration(milliseconds: 300));
    expect(backend.calls, hasLength(1));
    server.shutdown();
    server.delete();
    serverDeleted = true;
    backend.gate!.complete();
    await Future.delayed(const Duration(milliseconds: 100));
    client.delete();
    expect((await pending).serviceResult, isNot(raw.UA_STATUSCODE_GOOD));
  });

  test('ReadModified answers Bad_NotSupported', () async {
    final response = await client.read([node(temperature)], details: readRawDetails(isReadModified: true));
    expect(response.serviceResult, raw.UA_STATUSCODE_BADNOTSUPPORTED);
  });

  group('ReadProcessed and ReadAtTime', () {
    test('are unsupported per node unless the backend overrides them', () async {
      for (final details in [
        readProcessedDetails(processingInterval: 1000),
        readAtTimeDetails([dateTimeToUaDateTime(t0)]),
      ]) {
        final response = await client.read([node(temperature), node(plain)], details: details);
        expect(response.serviceResult, raw.UA_STATUSCODE_GOOD);
        expect(response.results.map((r) => r.statusCode), [
          raw.UA_STATUSCODE_BADHISTORYOPERATIONUNSUPPORTED,
          raw.UA_STATUSCODE_BADHISTORYOPERATIONINVALID,
        ]);
      }
    });

    test('reach an overriding backend', () async {
      final other = _AtTimeBackend();
      server.setHistoryBackend(other);
      final atTime = await client.read(
        [node(temperature)],
        details: readAtTimeDetails([
          dateTimeToUaDateTime(t0),
          dateTimeToUaDateTime(t0.add(const Duration(seconds: 2))),
        ]),
      );
      expect(valuesOf(atTime.results.single), [0, 2]);
      expect(other.atTime.single.times, [t0, t0.add(const Duration(seconds: 2))]);
      expect(other.atTime.single.useSimpleBounds, isTrue);

      final average = NodeId.fromNumeric(0, raw.UA_NS0ID_AGGREGATEFUNCTION_AVERAGE);
      final processed = await client.read(
        [node(temperature)],
        details: readProcessedDetails(
          startTime: dateTimeToUaDateTime(t0),
          endTime: dateTimeToUaDateTime(t0.add(const Duration(seconds: 10))),
          processingInterval: 5000,
          aggregateTypes: [average],
        ),
      );
      expect(valuesOf(processed.results.single), [42]);
      final request = other.processed.single;
      expect(request.processingInterval, const Duration(seconds: 5));
      expect(request.aggregateType, average);
      expect(request.start, t0);
    });
  });
}

class _AtTimeBackend extends HistoryBackend {
  final atTime = <HistoryReadAtTimeRequest>[];
  final processed = <HistoryReadProcessedRequest>[];

  @override
  Future<List<HistoryReadResult>> readRaw(List<HistoryReadRawRequest> nodes) async => throw UnimplementedError();

  @override
  Future<List<HistoryReadResult>> readAtTime(List<HistoryReadAtTimeRequest> nodes) async {
    atTime.addAll(nodes);
    return [
      for (final node in nodes)
        HistoryReadResult([
          for (final time in node.times)
            DataValue(
              value: DynamicValue(value: time.difference(t0).inSeconds, typeId: NodeId.int32),
              statusCode: raw.UA_STATUSCODE_GOOD,
              sourceTimestamp: time,
            ),
        ]),
    ];
  }

  @override
  Future<List<HistoryReadResult>> readProcessed(List<HistoryReadProcessedRequest> nodes) async {
    processed.addAll(nodes);
    return [
      for (final _ in nodes)
        HistoryReadResult([
          DataValue(
            value: DynamicValue(value: 42, typeId: NodeId.int32),
            statusCode: raw.UA_STATUSCODE_GOOD,
          ),
        ]),
    ];
  }
}
