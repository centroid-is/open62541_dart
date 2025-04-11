import 'package:ffi/ffi.dart';
import 'dart:convert';
import 'dart:ffi';

import 'generated/open62541_bindings.dart' as raw;

import 'types/string.dart';

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

// ignore: camel_case_types
enum UA_MessageSecurityModeEnum {
  invalid(raw.UA_MessageSecurityMode.UA_MESSAGESECURITYMODE_INVALID),
  none(raw.UA_MessageSecurityMode.UA_MESSAGESECURITYMODE_NONE),
  sign(raw.UA_MessageSecurityMode.UA_MESSAGESECURITYMODE_SIGN),
  signAndEncrypt(
      raw.UA_MessageSecurityMode.UA_MESSAGESECURITYMODE_SIGNANDENCRYPT);

  final int value;
  const UA_MessageSecurityModeEnum(this.value);

  static UA_MessageSecurityModeEnum fromInt(int value) {
    return UA_MessageSecurityModeEnum.values.firstWhere(
      (mode) => mode.value == value,
      orElse: () =>
          throw ArgumentError('Unknown MessageSecurityMode value: $value'),
    );
  }
}

// ignore: camel_case_types
enum UA_ExtensionObjectEncodingEnum {
  encodedNoBody(
      raw.UA_ExtensionObjectEncoding.UA_EXTENSIONOBJECT_ENCODED_NOBODY),
  encodedByteString(
      raw.UA_ExtensionObjectEncoding.UA_EXTENSIONOBJECT_ENCODED_BYTESTRING),
  encodedXml(raw.UA_ExtensionObjectEncoding.UA_EXTENSIONOBJECT_ENCODED_XML),
  decoded(raw.UA_ExtensionObjectEncoding.UA_EXTENSIONOBJECT_DECODED),
  decodedNodelete(
      raw.UA_ExtensionObjectEncoding.UA_EXTENSIONOBJECT_DECODED_NODELETE);

  final int value;
  const UA_ExtensionObjectEncodingEnum(this.value);

  static UA_ExtensionObjectEncodingEnum fromInt(int value) {
    return UA_ExtensionObjectEncodingEnum.values.firstWhere(
      (encoding) => encoding.value == value,
      orElse: () =>
          throw ArgumentError('Unknown ExtensionObjectEncoding value: $value'),
    );
  }
}

// ignore: camel_case_types
enum Namespace0Id {
  boolean(raw.UA_NS0ID_BOOLEAN),
  sbyte(raw.UA_NS0ID_SBYTE),
  byte(raw.UA_NS0ID_BYTE),
  int16(raw.UA_NS0ID_INT16),
  uint16(raw.UA_NS0ID_UINT16),
  int32(raw.UA_NS0ID_INT32),
  uint32(raw.UA_NS0ID_UINT32),
  int64(raw.UA_NS0ID_INT64),
  uint64(raw.UA_NS0ID_UINT64),
  float(raw.UA_NS0ID_FLOAT),
  double(raw.UA_NS0ID_DOUBLE),
  string(raw.UA_NS0ID_STRING),
  dateTime(raw.UA_NS0ID_DATETIME),
  guid(raw.UA_NS0ID_GUID),
  byteString(raw.UA_NS0ID_BYTESTRING),
  xmlElement(raw.UA_NS0ID_XMLELEMENT),
  nodeId(raw.UA_NS0ID_NODEID),
  expandedNodeId(raw.UA_NS0ID_EXPANDEDNODEID),
  statusCode(raw.UA_NS0ID_STATUSCODE),
  qualifiedName(raw.UA_NS0ID_QUALIFIEDNAME),
  localizedText(raw.UA_NS0ID_LOCALIZEDTEXT),
  structure(raw.UA_NS0ID_STRUCTURE),
  dataValue(raw.UA_NS0ID_DATAVALUE),
  basedataType(raw.UA_NS0ID_BASEDATATYPE),
  diagnosticInfo(raw.UA_NS0ID_DIAGNOSTICINFO),
  number(raw.UA_NS0ID_NUMBER),
  integer(raw.UA_NS0ID_INTEGER),
  uinteger(raw.UA_NS0ID_UINTEGER),
  enumeration(raw.UA_NS0ID_ENUMERATION),
  image(raw.UA_NS0ID_IMAGE),
  references(raw.UA_NS0ID_REFERENCES);

  final int value;
  const Namespace0Id(this.value);

  static Namespace0Id fromInt(int value) {
    return Namespace0Id.values.firstWhere(
      (id) => id.value == value,
      orElse: () => throw ArgumentError('Unknown Namespace0Id value: $value'),
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

// ignore: camel_case_extensions
extension UA_NodeIdExtension on raw.UA_NodeId {
  String string() {
    switch (identifierType) {
      case raw.UA_NodeIdType.UA_NODEIDTYPE_NUMERIC:
        return 'ns=$namespaceIndex;i=${identifier.numeric}';
      case raw.UA_NodeIdType.UA_NODEIDTYPE_STRING:
        final str = identifier.string;
        if (str.length == 0 || str.data == nullptr) {
          return 'ns=$namespaceIndex;s=""';
        }
        return 'ns=$namespaceIndex;s="${str.value}"';
      default:
        return 'ns=$namespaceIndex;unknown($identifierType)';
    }
  }
}

// ignore: camel_case_extensions
extension UA_StringExtension on raw.UA_String {
  void set(String value) {
    free();
    final bytes = utf8.encode(value);
    final dataPtr = calloc<Uint8>(bytes.length);

    final byteList = dataPtr.asTypedList(bytes.length);
    byteList.setAll(0, bytes);

    length = bytes.length;
    data = dataPtr;
  }

  String get value {
    final bytes = data.asTypedList(length);
    return utf8.decode(bytes);
  }

  Iterable<int> get dataIterable => data.asTypedList(length);

  void free() {
    if (data != nullptr) {
      calloc.free(data);
      data = nullptr;
      length = 0;
    }
  }
}
