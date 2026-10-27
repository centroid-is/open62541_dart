import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'common.dart';
import 'history_memory_backend.dart';

/// `HistoryReadApi.historyReadRaw` on [Client] and [ClientIsolate], against a
/// server whose history comes from an in-memory [HistoryBackend].

final temperature = NodeId.fromString(1, 'history.temperature');
final pressure = NodeId.fromString(1, 'history.pressure');
final plain = NodeId.fromString(1, 'history.plain');
final missing = NodeId.fromString(1, 'history.missing');

void main() {
  for (final clientType in clientTypes) {
    group('$clientType client', () {
      late Server server;
      late ClientApi api;
      late HistoryReadApi client;
      late MemoryBackend backend;

      setUp(() async {
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
        api = await setupClientOfType(clientType, 'opc.tcp://127.0.0.1:${server.port}');
        client = api as HistoryReadApi;
      });

      tearDown(() async {
        await api.delete();
        server.shutdown();
        server.delete();
      });

      List<Object?> valuesOf(List<DataValue> values) => values.map((v) => v.value.value).toList();

      test('reads several nodes in one request', () async {
        final history = await client.historyReadRaw([temperature, pressure]);
        expect(history.keys, [temperature, pressure]);
        expect(valuesOf(history[temperature]!), [0, 1, 2, 3, 4]);
        expect(valuesOf(history[pressure]!), [100, 101, 102]);
        expect(backend.calls, hasLength(1));
        final first = history[temperature]!.first;
        expect(first.statusCode, UA_STATUSCODE_GOOD);
        expect(first.sourceTimestamp, t0);
        expect(first.serverTimestamp, isNull, reason: 'source timestamps by default');
        expect(first.value.typeId, NodeId.int32);
      });

      test('timestampsToReturn both brings the server timestamps', () async {
        final history = await client.historyReadRaw([
          temperature,
        ], timestampsToReturn: TimestampsToReturn.UA_TIMESTAMPSTORETURN_BOTH);
        expect(history[temperature]!.first.serverTimestamp, t0.add(const Duration(milliseconds: 1)));
      });

      test('the interval and bounds reach the server', () async {
        final history = await client.historyReadRaw(
          [temperature],
          start: t0.add(const Duration(seconds: 1)),
          end: t0.add(const Duration(seconds: 3)),
          returnBounds: true,
        );
        expect(valuesOf(history[temperature]!), [1, 2]);
        final request = backend.calls.single.single;
        expect(request.start, t0.add(const Duration(seconds: 1)));
        expect(request.end, t0.add(const Duration(seconds: 3)));
        expect(request.returnBounds, isTrue);
      });

      test('follows continuation points until every node is done', () async {
        final history = await client.historyReadRaw([temperature, pressure], numValuesPerNode: 2);
        expect(valuesOf(history[temperature]!), [0, 1, 2, 3, 4]);
        expect(valuesOf(history[pressure]!), [100, 101, 102]);
        expect(backend.calls.map((c) => c.map((r) => r.nodeId).toList()), [
          [temperature, pressure],
          [temperature, pressure],
          [temperature],
        ]);
        expect(backend.released, isEmpty);
      });

      test('follows a continuation point that comes with no values', () async {
        backend.emptyFirstPage = true;
        final history = await client.historyReadRaw([temperature], numValuesPerNode: 2);
        expect(valuesOf(history[temperature]!), [0, 1, 2, 3, 4]);
        expect(backend.calls, hasLength(4));
      });

      test('maxValues stops a node and releases its continuation point', () async {
        final history = await client.historyReadRaw([temperature, pressure], numValuesPerNode: 2, maxValues: 3);
        expect(valuesOf(history[temperature]!), [0, 1, 2]);
        expect(valuesOf(history[pressure]!), [100, 101, 102]);
        expect(backend.released.map(offsetOf), [4]);
        expect(backend.calls, hasLength(2), reason: 'no read after the release');
      });

      test('maxValues reached on the first page releases at once', () async {
        final history = await client.historyReadRaw([temperature], numValuesPerNode: 2, maxValues: 2);
        expect(valuesOf(history[temperature]!), [0, 1]);
        expect(backend.released.map(offsetOf), [2]);
        expect(backend.calls, hasLength(1));
      });

      test('a node answered Bad fails the call with its status and releases the others', () async {
        await expectLater(
          client.historyReadRaw([temperature, missing], numValuesPerNode: 2),
          throwsA(
            isA<UaStatusException>().having((e) => e.statusCode, 'statusCode', raw.UA_STATUSCODE_BADNODEIDUNKNOWN),
          ),
        );
        expect(backend.released.map(offsetOf), [2]);

        await expectLater(
          client.historyReadRaw([plain]),
          throwsA(
            isA<UaStatusException>().having(
              (e) => e.statusCode,
              'statusCode',
              raw.UA_STATUSCODE_BADHISTORYOPERATIONINVALID,
            ),
          ),
        );
      });

      test('a backend failure on a later page fails the call', () async {
        final first = client.historyReadRaw([temperature], numValuesPerNode: 2);
        backend.failAfter = 1;
        backend.error = const UaStatusException(raw.UA_STATUSCODE_BADCONTINUATIONPOINTINVALID);
        await expectLater(
          first,
          throwsA(
            isA<UaStatusException>().having(
              (e) => e.statusCode,
              'statusCode',
              raw.UA_STATUSCODE_BADCONTINUATIONPOINTINVALID,
            ),
          ),
        );
        // The page that failed carried no continuation point: nothing is
        // left on the server to release.
        expect(backend.released, isEmpty);
      });

      test('a Bad service result fails the call', () async {
        await expectLater(
          client.historyReadRaw([temperature], timestampsToReturn: TimestampsToReturn.UA_TIMESTAMPSTORETURN_NEITHER),
          throwsA(
            isA<UaStatusException>().having(
              (e) => e.statusCode,
              'statusCode',
              raw.UA_STATUSCODE_BADTIMESTAMPSTORETURNINVALID,
            ),
          ),
        );
        server.setHistoryBackend(null);
        await expectLater(
          client.historyReadRaw([temperature]),
          throwsA(
            isA<UaStatusException>().having((e) => e.statusCode, 'statusCode', raw.UA_STATUSCODE_BADNOTSUPPORTED),
          ),
        );
      });

      test('no nodes is no request; a repeated node is read once', () async {
        expect(await client.historyReadRaw([]), isEmpty);
        expect(backend.calls, isEmpty);
        final history = await client.historyReadRaw([temperature, temperature]);
        expect(history.keys, [temperature]);
        expect(backend.calls.single, hasLength(1));
      });

      test('a negative maxValues is refused', () async {
        await expectLater(client.historyReadRaw([temperature], maxValues: -1), throwsA(anything));
        expect(backend.calls, isEmpty);
      });
    });
  }
}
