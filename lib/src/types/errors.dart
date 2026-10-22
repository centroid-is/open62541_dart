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

/// A value's DataType disagrees with the type actually on the wire: the server
/// advertised one built-in type for the value (via the DataType attribute a
/// read supplies as a decode hint) but the variant it sent carries another.
/// Decoding the native bytes under the advertised type would read memory with
/// the wrong layout, so the decoder refuses. Thrown by `Client.read` (and any
/// decode given a DataType hint); the client stays usable.
///
/// Extends [UaStatusException] with `Bad_TypeMismatch`, so an `on
/// UaStatusException` handler sees it and it crosses the `ClientIsolate`
/// boundary as itself (its [expected] / [actual] NodeIds survive).
class UaTypeMismatch extends UaStatusException {
  UaTypeMismatch({required this.expected, required this.actual}) : super(0x80730000 /* Bad_TypeMismatch */);

  /// The type the server advertised for the value (the DataType hint).
  final NodeId expected;

  /// The type the variant actually carried on the wire.
  final NodeId actual;

  @override
  String toString() => 'UaTypeMismatch: the value is typed $expected but the wire carries $actual';
}

/// The DataTypeDefinitions a server serves for a structured type lead back to
/// a type that is still being resolved (a field of type A inside A, or A → B
/// → A): the definition is invalid (Part 3: a structure cannot contain itself
/// by value) and its schema cannot be built. Thrown by `Client.buildSchema`,
/// so a `read`, `readValue`, `call` or monitor of a value of that type fails
/// with it instead of fetching definitions forever; the client stays usable.
/// Crosses the `ClientIsolate` boundary as its message.
class DataTypeDefinitionCycle implements Exception {
  DataTypeDefinitionCycle(this.path);

  /// The DataType ids from the repeated type down to the field that names it
  /// again, so `path.first == path.last`.
  final List<NodeId> path;

  @override
  String toString() => 'DataTypeDefinitionCycle: the DataTypeDefinition of ${path.join(' -> ')} contains itself';
}

/// A structured type's DataTypeDefinitions nest deeper than
/// [DataTypeDefinitionTooDeep.limit] levels: the backstop (the bound
/// open62541's binary decoder uses) behind [DataTypeDefinitionCycle] for a
/// server that serves a new definition at every level.
class DataTypeDefinitionTooDeep implements Exception {
  DataTypeDefinitionTooDeep(this.path);

  /// The deepest nesting of struct-typed fields a schema is built for.
  static const limit = 100;

  /// The DataType ids from the root type down to the one past [limit].
  final List<NodeId> path;

  @override
  String toString() =>
      'DataTypeDefinitionTooDeep: the DataTypeDefinition of ${path.first} nests more than $limit levels '
      '(at ${path.last})';
}

class Inactivity extends Error {}

class SubscriptionDeleted extends Error {
  final int subscriptionId;
  SubscriptionDeleted(this.subscriptionId);

  @override
  String toString() => 'SubscriptionDeleted(subscriptionId: $subscriptionId)';
}

class SecureChannelClosed extends Error {}
