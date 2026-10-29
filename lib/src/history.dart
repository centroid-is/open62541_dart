import 'dart:typed_data';

import 'client.dart' show DataValue;
import 'extensions.dart';
import 'node_id.dart';
import 'server.dart' show MethodSessionInfo;
import 'third_party/open62541.g.dart' as raw;
import 'types/errors.dart';

/// What a client asked of one node in a HistoryRead with ReadRawModifiedDetails
/// (raw values, not modified ones), copied out of the request.
class HistoryReadRawRequest {
  const HistoryReadRawRequest({
    required this.nodeId,
    required this.start,
    required this.end,
    required this.numValuesPerNode,
    required this.returnBounds,
    required this.timestampsToReturn,
    required this.session,
    this.indexRange,
    this.continuationPoint,
  });

  final NodeId nodeId;

  /// The start of the interval, `null` when the client left it unspecified.
  final DateTime? start;

  /// The end of the interval, `null` when the client left it unspecified.
  /// Part 11: with [start] after [end] the values are returned in reverse
  /// order.
  final DateTime? end;

  /// The most values to return for the node in this response, `0` for no
  /// limit. Already capped by `Server.setHistoryBackend`'s
  /// `maxReturnDataValues`. A backend with more values returns this many and a
  /// [HistoryReadResult.continuationPoint].
  final int numValuesPerNode;

  /// Whether the client asked for the bounding values.
  final bool returnBounds;

  /// Which timestamps the client wants: `source`, `server` or `both`
  /// (`neither` is refused before the backend is called). The values are
  /// ordered by this timestamp.
  final TimestampsToReturn timestampsToReturn;

  /// The client's IndexRange for array values, `null` when absent. A backend
  /// that does not apply it answers `Bad_IndexRangeInvalid`.
  final String? indexRange;

  /// The backend's own bytes from a previous page, `null` on a first request.
  final Uint8List? continuationPoint;

  /// The session that sent the request, resolved when it arrived.
  final MethodSessionInfo session;

  @override
  String toString() =>
      'HistoryReadRawRequest($nodeId, start: $start, end: $end, numValuesPerNode: $numValuesPerNode, '
      'continuationPoint: ${continuationPoint?.length})';
}

/// What a client asked of one node in a HistoryRead with ReadAtTimeDetails.
class HistoryReadAtTimeRequest {
  const HistoryReadAtTimeRequest({
    required this.nodeId,
    required this.times,
    required this.useSimpleBounds,
    required this.timestampsToReturn,
    required this.session,
    this.indexRange,
    this.continuationPoint,
  });

  final NodeId nodeId;

  /// The instants to return a value for, in the client's order.
  final List<DateTime> times;
  final bool useSimpleBounds;
  final TimestampsToReturn timestampsToReturn;
  final String? indexRange;
  final Uint8List? continuationPoint;
  final MethodSessionInfo session;
}

/// What a client asked of one node in a HistoryRead with
/// ReadProcessedDetails.
class HistoryReadProcessedRequest {
  const HistoryReadProcessedRequest({
    required this.nodeId,
    required this.start,
    required this.end,
    required this.processingInterval,
    required this.aggregateType,
    required this.timestampsToReturn,
    required this.session,
    this.indexRange,
    this.continuationPoint,
  });

  final NodeId nodeId;
  final DateTime? start;
  final DateTime? end;

  /// The length of each interval the aggregate is computed over.
  final Duration processingInterval;

  /// The aggregate function this node is read with (the request's
  /// aggregateType entry at this node's position), `null` when the request
  /// has none for it.
  final NodeId? aggregateType;
  final TimestampsToReturn timestampsToReturn;
  final String? indexRange;
  final Uint8List? continuationPoint;
  final MethodSessionInfo session;
}

/// A backend's answer for one node.
class HistoryReadResult {
  const HistoryReadResult(this.values, {this.continuationPoint, this.statusCode = raw.UA_STATUSCODE_GOOD});

  /// The node's values, in the order the request calls for. Each
  /// [DataValue.sourceTimestamp] / [DataValue.serverTimestamp] is sent when
  /// the client asked for that timestamp; a non-Good [DataValue.statusCode]
  /// is sent with the value.
  final List<DataValue> values;

  /// Opaque bytes the client sends back for the next page; `null` when the
  /// node is done. The server keeps no record of them: the backend mints,
  /// checks and expires its own.
  final Uint8List? continuationPoint;

  /// The node's status, e.g. `UA_STATUSCODE_GOODNODATA` or
  /// `UA_STATUSCODE_BADCONTINUATIONPOINTINVALID`.
  final int statusCode;
}

/// The history store behind a server's HistoryRead service
/// (`Server.setHistoryBackend`).
///
/// Every method is called on the server's isolate, from within
/// `Server.runIterate`, once per HistoryRead request with the nodes that
/// passed the server's checks, in request order. It returns a [Future]: the
/// client's request stays parked, without blocking the server, until it
/// completes or `Server.asyncOperationTimeout` cancels it (`Bad_Timeout`). It
/// completes with one [HistoryReadResult] per request, in the same order. A
/// [UaStatusException] (thrown or as the error of the future) answers every
/// node with its status code, any other error with `Bad_InternalError`.
abstract class HistoryBackend {
  /// Reads raw values (ReadRawModifiedDetails with `isReadModified` false).
  Future<List<HistoryReadResult>> readRaw(List<HistoryReadRawRequest> nodes);

  /// The client gave up on these continuation points
  /// (`releaseContinuationPoints`); answered right away, with no data. Called
  /// for every kind of read.
  void releaseContinuationPoints(List<Uint8List> continuationPoints) {}

  /// Reads aggregates (ReadProcessedDetails). Unsupported unless overridden:
  /// every node gets `Bad_HistoryOperationUnsupported`.
  Future<List<HistoryReadResult>> readProcessed(List<HistoryReadProcessedRequest> nodes) =>
      throw const UaStatusException(raw.UA_STATUSCODE_BADHISTORYOPERATIONUNSUPPORTED);

  /// Reads values at given instants (ReadAtTimeDetails). Unsupported unless
  /// overridden: every node gets `Bad_HistoryOperationUnsupported`.
  Future<List<HistoryReadResult>> readAtTime(List<HistoryReadAtTimeRequest> nodes) =>
      throw const UaStatusException(raw.UA_STATUSCODE_BADHISTORYOPERATIONUNSUPPORTED);
}
