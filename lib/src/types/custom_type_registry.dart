// The DefaultBinary DataTypeEncoding ids of the custom structured DataTypes a
// `Server` in this process registered. Package-private: not exported from
// lib/open62541.dart.

import '../node_id.dart';

final Map<NodeId, NodeId> _encodingByDataType = {};
final Map<NodeId, NodeId> _dataTypeByEncoding = {};

/// The DefaultBinary DataTypeEncoding NodeId of a custom structured DataType
/// (OPC 10000-3 §8.2, OPC 10000-6 §5.2.2.15): the id every ExtensionObject of
/// that type carries on the wire and the id its DataType node advertises in
/// `DataTypeDefinition.defaultEncodingId`.
///
/// The rule (stable; a client that cached it must find it unchanged):
/// `ns=N;s=Name` → `ns=N;s=Name_Encoding_DefaultBinary`, the OPC UA naming
/// convention (NS0: `Argument` i=296 ↔ `Argument_Encoding_DefaultBinary`
/// i=298). A numeric or other identifier gets a string id derived the same
/// way from its text: `ns=N;i=42` → `ns=N;s=42_Encoding_DefaultBinary`,
/// `ns=N;g=<guid>` → `ns=N;s=g=<guid>_Encoding_DefaultBinary`. Derived from
/// the typeId, which is unique by construction, never from the schema's
/// name (which may be null or shared by nested, auto-registered schemas).
NodeId defaultBinaryEncodingIdOf(NodeId typeId) {
  final String identifier;
  if (typeId.isString()) {
    identifier = typeId.string;
  } else if (typeId.isNumeric()) {
    identifier = '${typeId.numeric}';
  } else {
    final text = typeId.toString();
    final semicolon = text.indexOf(';');
    identifier = semicolon < 0 ? text : text.substring(semicolon + 1);
  }
  return NodeId.fromString(typeId.namespace, '${identifier}_Encoding_DefaultBinary');
}

/// Records [encodingId] as the DefaultBinary encoding of the custom
/// structured DataType [typeId].
void registerCustomBinaryEncodingId(NodeId typeId, NodeId encodingId) {
  _encodingByDataType[typeId] = encodingId;
  _dataTypeByEncoding[encodingId] = typeId;
}

/// The registered DefaultBinary encoding id of custom DataType [typeId], or
/// null when no server in this process registered it.
NodeId? customBinaryEncodingIdOf(NodeId typeId) => _encodingByDataType[typeId];

/// The custom DataType whose registered DefaultBinary encoding id is
/// [encodingId], or null.
NodeId? customDataTypeOfEncoding(NodeId encodingId) => _dataTypeByEncoding[encodingId];
