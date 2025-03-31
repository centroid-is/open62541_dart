import 'generated/open62541_bindings.dart' as raw;

// ignore: camel_case_types
enum UA_DataTypeKindEnum {
  boolean(raw.UA_DataTypeKind.UA_DATATYPEKIND_BOOLEAN),
  sbyte(raw.UA_DataTypeKind.UA_DATATYPEKIND_SBYTE),
  byte(raw.UA_DataTypeKind.UA_DATATYPEKIND_BYTE),
  int16(raw.UA_DataTypeKind.UA_DATATYPEKIND_INT16),
  uint16(raw.UA_DataTypeKind.UA_DATATYPEKIND_UINT16),
  int32(raw.UA_DataTypeKind.UA_DATATYPEKIND_INT32),
  uint32(raw.UA_DataTypeKind.UA_DATATYPEKIND_UINT32),
  int64(raw.UA_DataTypeKind.UA_DATATYPEKIND_INT64),
  uint64(raw.UA_DataTypeKind.UA_DATATYPEKIND_UINT64),
  float(raw.UA_DataTypeKind.UA_DATATYPEKIND_FLOAT),
  double(raw.UA_DataTypeKind.UA_DATATYPEKIND_DOUBLE),
  string(raw.UA_DataTypeKind.UA_DATATYPEKIND_STRING),
  dateTime(raw.UA_DataTypeKind.UA_DATATYPEKIND_DATETIME),
  guid(raw.UA_DataTypeKind.UA_DATATYPEKIND_GUID),
  byteString(raw.UA_DataTypeKind.UA_DATATYPEKIND_BYTESTRING),
  xmlElement(raw.UA_DataTypeKind.UA_DATATYPEKIND_XMLELEMENT),
  nodeId(raw.UA_DataTypeKind.UA_DATATYPEKIND_NODEID),
  expandedNodeId(raw.UA_DataTypeKind.UA_DATATYPEKIND_EXPANDEDNODEID),
  statusCode(raw.UA_DataTypeKind.UA_DATATYPEKIND_STATUSCODE),
  qualifiedName(raw.UA_DataTypeKind.UA_DATATYPEKIND_QUALIFIEDNAME),
  localizedText(raw.UA_DataTypeKind.UA_DATATYPEKIND_LOCALIZEDTEXT),
  extensionObject(raw.UA_DataTypeKind.UA_DATATYPEKIND_EXTENSIONOBJECT),
  dataValue(raw.UA_DataTypeKind.UA_DATATYPEKIND_DATAVALUE),
  variant(raw.UA_DataTypeKind.UA_DATATYPEKIND_VARIANT),
  diagnosticInfo(raw.UA_DataTypeKind.UA_DATATYPEKIND_DIAGNOSTICINFO),
  decimal(raw.UA_DataTypeKind.UA_DATATYPEKIND_DECIMAL),
  enum_(raw.UA_DataTypeKind.UA_DATATYPEKIND_ENUM),
  structure(raw.UA_DataTypeKind.UA_DATATYPEKIND_STRUCTURE),
  optStruct(raw.UA_DataTypeKind.UA_DATATYPEKIND_OPTSTRUCT),
  union(raw.UA_DataTypeKind.UA_DATATYPEKIND_UNION),
  bitfieldCluster(raw.UA_DataTypeKind.UA_DATATYPEKIND_BITFIELDCLUSTER);

  final int value;
  const UA_DataTypeKindEnum(this.value);

  static UA_DataTypeKindEnum fromInt(int value) {
    return UA_DataTypeKindEnum.values.firstWhere(
      (kind) => kind.value == value,
      orElse: () => throw ArgumentError('Unknown DataTypeKind value: $value'),
    );
  }
}

// ignore: camel_case_extensions
extension UA_DataTypeExtension on raw.UA_DataType {
  int get memSize => substitute & 0xFFFF; // First 16 bits
  UA_DataTypeKindEnum get typeKind =>
      UA_DataTypeKindEnum.fromInt((substitute >> 16) & 0x3F); // Next 6 bits
  bool get pointerFree => ((substitute >> 22) & 0x1) == 1; // Next 1 bit
  bool get overlayable => ((substitute >> 23) & 0x1) == 1; // Next 1 bit
  int get membersSize => (substitute >> 24) & 0xFF; // Last 8 bits
}
