import '../common.dart' show statusCodeToString;

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

class Inactivity extends Error {}

class SubscriptionDeleted extends Error {
  final int subscriptionId;
  SubscriptionDeleted(this.subscriptionId);

  @override
  String toString() => 'SubscriptionDeleted(subscriptionId: $subscriptionId)';
}

class SecureChannelClosed extends Error {}
