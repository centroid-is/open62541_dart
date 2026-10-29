import 'dart:async';
import 'dart:typed_data';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;

final t0 = DateTime.utc(2026, 1, 1);

/// [count] Int32 samples one second apart from [t0], value `base + i`, with
/// the server timestamp 1 ms after the source timestamp.
List<DataValue> samples(int count, {int base = 0}) => [
  for (var i = 0; i < count; i++)
    DataValue(
      value: DynamicValue(value: base + i, typeId: NodeId.int32),
      statusCode: raw.UA_STATUSCODE_GOOD,
      sourceTimestamp: t0.add(Duration(seconds: i)),
      serverTimestamp: t0.add(Duration(seconds: i, milliseconds: 1)),
    ),
];

Uint8List cpFor(int offset) => Uint8List(4)..buffer.asByteData().setUint32(0, offset);
int offsetOf(Uint8List cp) => cp.buffer.asByteData().getUint32(0);

/// An in-memory store: [series] per node, paged by [HistoryReadRawRequest.numValuesPerNode]
/// with the offset of the next value as continuation point. [delay] and
/// [gate] hold the answer back; [error] makes it fail.
class MemoryBackend extends HistoryBackend {
  MemoryBackend(this.series);

  final Map<NodeId, List<DataValue>> series;
  Duration delay = Duration.zero;
  Completer<void>? gate;
  Object? error;

  /// With [error]: the calls before this many succeed.
  int? failAfter;
  Object? syncError;
  Object? releaseError;
  int? resultCount;
  final calls = <List<HistoryReadRawRequest>>[];
  final released = <Uint8List>[];

  /// Answer every first request (no continuation point) with an empty page
  /// and a continuation point to the start, as a slow store may.
  bool emptyFirstPage = false;

  @override
  Future<List<HistoryReadResult>> readRaw(List<HistoryReadRawRequest> nodes) {
    calls.add(nodes);
    if (syncError != null) throw syncError!;
    return _answer(nodes);
  }

  Future<List<HistoryReadResult>> _answer(List<HistoryReadRawRequest> nodes) async {
    await Future.delayed(delay);
    if (gate != null) await gate!.future;
    if (error != null && (failAfter == null || calls.length > failAfter!)) throw error!;
    final results = [for (final node in nodes) page(node)];
    return resultCount == null ? results : results.take(resultCount!).toList();
  }

  HistoryReadResult page(HistoryReadRawRequest node) {
    if (emptyFirstPage && node.continuationPoint == null) {
      return HistoryReadResult(const [], continuationPoint: cpFor(0));
    }
    final all = (series[node.nodeId] ?? const <DataValue>[])
        .where((v) => node.start == null || !v.sourceTimestamp!.isBefore(node.start!))
        .where((v) => node.end == null || v.sourceTimestamp!.isBefore(node.end!))
        .toList();
    final offset = node.continuationPoint == null ? 0 : offsetOf(node.continuationPoint!);
    final take = node.numValuesPerNode == 0 ? all.length - offset : node.numValuesPerNode;
    final end = (offset + take).clamp(offset, all.length);
    return HistoryReadResult(
      all.sublist(offset, end),
      continuationPoint: end < all.length ? cpFor(end) : null,
      statusCode: all.isEmpty ? raw.UA_STATUSCODE_GOODNODATA : raw.UA_STATUSCODE_GOOD,
    );
  }

  @override
  void releaseContinuationPoints(List<Uint8List> continuationPoints) {
    released.addAll(continuationPoints);
    if (releaseError != null) throw releaseError!;
  }
}
