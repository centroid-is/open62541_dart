import 'node_id.dart';
import 'third_party/open62541.g.dart' as raw;

/// The OPC UA PubSub transport profile URI for UDP + UADP (the broker-less
/// datagram transport used with `opc.udp://` addresses). This is the default
/// transport for `Server.addPubSubConnection`.
const String pubSubTransportUdpUadp = 'http://opcfoundation.org/UA-Profile/Transport/pubsub-udp-uadp';

/// The wire type of a PubSub PublisherId (OPC UA Part 14, 7.2.2.2.2).
enum PubSubPublisherIdType { byte, uint16, uint32, uint64, string }

/// A PubSub PublisherId: the identifier a Publisher stamps into every
/// NetworkMessage, and the first key a DataSetReader matches on.
///
/// The id is a tagged union of one of five wire types. The type is part of the
/// match: a reader configured with `PubSubPublisherId.uint16(2234)` does NOT
/// match a publisher configured with `PubSubPublisherId.uint32(2234)`.
///
/// Example:
/// ```dart
/// final connection = server.addPubSubConnection(
///   name: 'UADP Connection',
///   url: 'opc.udp://224.0.0.22:4840/',
///   publisherId: PubSubPublisherId.uint16(2234),
/// );
/// ```
class PubSubPublisherId {
  const PubSubPublisherId.byte(int this.numeric) : type = PubSubPublisherIdType.byte, string = null;
  const PubSubPublisherId.uint16(int this.numeric) : type = PubSubPublisherIdType.uint16, string = null;
  const PubSubPublisherId.uint32(int this.numeric) : type = PubSubPublisherIdType.uint32, string = null;
  const PubSubPublisherId.uint64(int this.numeric) : type = PubSubPublisherIdType.uint64, string = null;
  const PubSubPublisherId.string(String this.string) : type = PubSubPublisherIdType.string, numeric = null;

  final PubSubPublisherIdType type;

  /// The numeric identifier; `null` for a [PubSubPublisherIdType.string] id.
  final int? numeric;

  /// The string identifier; `null` for the numeric id types.
  final String? string;

  @override
  String toString() => 'PublisherId(${type.name}: ${string ?? numeric})';
}

/// Describes one field of a DataSet on the subscriber side.
///
/// A DataSetReader needs the DataSetMetaData — the ordered list of fields the
/// matched DataSetWriter publishes — to decode incoming DataSetMessages. Each
/// entry names the field and gives its data type; order must match the order in
/// which the publisher added its dataset fields.
///
/// * [name] - The field name (informational; shown in the information model).
/// * [dataType] - The field's DataType. Must be a builtin namespace-0 type
///   (e.g. [NodeId.int32], [NodeId.double], [NodeId.boolean]).
/// * [valueRank] - `-1` (the default) for a scalar, `1` for a one-dimensional
///   array.
/// * [arrayDimensions] - Optional array dimensions for array fields.
class DataSetFieldMeta {
  const DataSetFieldMeta({
    required this.name,
    required this.dataType,
    this.valueRank = -1,
    this.arrayDimensions = const [],
  });

  final String name;
  final NodeId dataType;
  final int valueRank;
  final List<int> arrayDimensions;
}

/// The runtime state of a PubSub component (connection, writer/reader group,
/// dataset writer/reader). Mirrors open62541's `UA_PubSubState`.
///
/// [disabled] and [error] require a manual re-enable; the other states are
/// "enabled" and converge to [operational] on their own when the external
/// conditions allow it (e.g. a ReaderGroup only becomes operational once the
/// first message for it has been received — until then it reports
/// [preOperational]).
enum PubSubState {
  disabled,
  paused,
  operational,
  error,
  preOperational;

  static PubSubState fromRaw(int value) {
    return switch (value) {
      0 => PubSubState.disabled,
      1 => PubSubState.paused,
      2 => PubSubState.operational,
      3 => PubSubState.error,
      4 => PubSubState.preOperational,
      _ => throw 'Unknown UA_PubSubState value: $value',
    };
  }
}

/// The default UADP NetworkMessage content mask used by
/// `Server.addWriterGroup`: PublisherId + GroupHeader + WriterGroupId +
/// PayloadHeader. These headers carry the identifiers a DataSetReader matches
/// on (publisherId / writerGroupId / dataSetWriterId), so they must be present
/// for the subscriber side to associate incoming messages.
const int uadpDefaultNetworkMessageContentMask =
    raw.UA_UADPNETWORKMESSAGECONTENTMASK_PUBLISHERID |
    raw.UA_UADPNETWORKMESSAGECONTENTMASK_GROUPHEADER |
    raw.UA_UADPNETWORKMESSAGECONTENTMASK_WRITERGROUPID |
    raw.UA_UADPNETWORKMESSAGECONTENTMASK_PAYLOADHEADER;
