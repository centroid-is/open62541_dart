import '../common.dart' show statusCodeToString;
import '../extensions.dart' show AttributeId;
import '../node_id.dart' show NodeId;

/// An OPC UA status code carried as a typed exception, so the exact code is
/// programmatically extractable (rather than only a formatted message).
///
/// Two roles:
///  * **Server side**: throw it from a data-source `onWrite` / `onRead` /
///    `onReadValue` callback (see `Server.addDataSourceVariableNode`) to
///    answer the client with that exact status code — e.g.
///    `throw UaStatusException(UA_STATUSCODE_BADNOTWRITABLE)`. Any other
///    thrown object still maps to `Bad_InternalError`.
///  * **Client side**: `Client.write` fails with a [UaStatusException]
///    carrying the operation/service status, and a monitored-item stream
///    delivers one as its error event when a notification arrives with a
///    non-Good status.
class UaStatusException implements Exception {
  const UaStatusException(this.statusCode);

  /// The raw OPC UA status code (e.g. `0x803B0000` = `Bad_NotWritable`).
  final int statusCode;

  @override
  String toString() =>
      'UaStatusException(0x${statusCode.toRadixString(16).padLeft(8, '0')}: ${statusCodeToString(statusCode)})';
}

/// The server refused one or more of the items a `monitoredItems` stream
/// asked for (a NodeId it does not have, an attribute it will not monitor,
/// ...): the stream's error event, in place of the `String` it used to be.
///
/// [failures] has the status of every refused item by `(NodeId, AttributeId)`;
/// [statusCode] is the status of the first of them, so an `on
/// UaStatusException` handler sees it like any other status failure.
/// Crosses the `ClientIsolate` boundary as itself.
class MonitoredItemsRefused extends UaStatusException {
  MonitoredItemsRefused(this.failures) : super(failures.values.first);

  /// The refused items and the status the server answered each with.
  final Map<(NodeId, AttributeId), int> failures;

  @override
  String toString() =>
      'Unable to create monitored item: ${failures.entries.map((e) => "${e.key}: ${statusCodeToString(e.value)}").join(", ")}';
}

class Inactivity extends Error {}

class SubscriptionDeleted extends Error {
  final int subscriptionId;
  SubscriptionDeleted(this.subscriptionId);

  @override
  String toString() => 'SubscriptionDeleted(subscriptionId: $subscriptionId)';
}

class SecureChannelClosed extends Error {}
