import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'dart:convert';
import 'dart:ffi';

import 'dynamic_value.dart';
import 'node_id.dart';
import 'generated/open62541_bindings.dart' as raw;

// ignore: camel_case_types
enum TypeKindEnum {
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
  datetime(raw.UA_DataTypeKind.UA_DATATYPEKIND_DATETIME),
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
  bitfieldCluster(raw.UA_DataTypeKind.UA_DATATYPEKIND_BITFIELDCLUSTER),
  outOfSpecContiguousString(
      99); // I dont like this, but when we use namespace 0 id type string, that will be this value

  final int value;
  const TypeKindEnum(this.value);

  static TypeKindEnum fromInt(int value) {
    return TypeKindEnum.values.firstWhere(
      (kind) => kind.value == value,
      orElse: () => throw ArgumentError('Unknown DataTypeKind value: $value'),
    );
  }

  Namespace0Id toNamespace0Id() {
    switch (this) {
      case TypeKindEnum.boolean:
        return Namespace0Id.boolean;
      case TypeKindEnum.sbyte:
        return Namespace0Id.sbyte;
      case TypeKindEnum.byte:
        return Namespace0Id.byte;
      case TypeKindEnum.int16:
        return Namespace0Id.int16;
      case TypeKindEnum.uint16:
        return Namespace0Id.uint16;
      case TypeKindEnum.int32:
        return Namespace0Id.int32;
      case TypeKindEnum.uint32:
        return Namespace0Id.uint32;
      case TypeKindEnum.int64:
        return Namespace0Id.int64;
      case TypeKindEnum.uint64:
        return Namespace0Id.uint64;
      case TypeKindEnum.float:
        return Namespace0Id.float;
      case TypeKindEnum.double:
        return Namespace0Id.double;
      case TypeKindEnum.string:
      case TypeKindEnum.outOfSpecContiguousString:
        return Namespace0Id.string;
      case TypeKindEnum.datetime:
        return Namespace0Id.datetime;
      case TypeKindEnum.guid:
        return Namespace0Id.guid;
      case TypeKindEnum.byteString:
        return Namespace0Id.byteString;
      case TypeKindEnum.xmlElement:
        return Namespace0Id.xmlElement;
      case TypeKindEnum.nodeId:
        return Namespace0Id.nodeId;
      case TypeKindEnum.expandedNodeId:
        return Namespace0Id.expandedNodeId;
      case TypeKindEnum.statusCode:
        return Namespace0Id.statusCode;
      case TypeKindEnum.qualifiedName:
        return Namespace0Id.qualifiedName;
      case TypeKindEnum.localizedText:
        return Namespace0Id.localizedText;
      case TypeKindEnum.structure:
        return Namespace0Id.structure;
      case TypeKindEnum.dataValue:
        return Namespace0Id.dataValue;
      // case Namespace0Id.basedataType:
      //   return TypeKindEnum.basedataType;
      case TypeKindEnum.diagnosticInfo:
        return Namespace0Id.diagnosticInfo;
      default:
        throw ArgumentError('Unknown TypeKindEnum value: $this');
    }
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
  datetime(raw.UA_NS0ID_DATETIME),
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

  TypeKindEnum toTypeKind() {
    switch (this) {
      case Namespace0Id.boolean:
        return TypeKindEnum.boolean;
      case Namespace0Id.sbyte:
        return TypeKindEnum.sbyte;
      case Namespace0Id.byte:
        return TypeKindEnum.byte;
      case Namespace0Id.int16:
        return TypeKindEnum.int16;
      case Namespace0Id.uint16:
        return TypeKindEnum.uint16;
      case Namespace0Id.int32:
        return TypeKindEnum.int32;
      case Namespace0Id.uint32:
        return TypeKindEnum.uint32;
      case Namespace0Id.int64:
        return TypeKindEnum.int64;
      case Namespace0Id.uint64:
        return TypeKindEnum.uint64;
      case Namespace0Id.float:
        return TypeKindEnum.float;
      case Namespace0Id.double:
        return TypeKindEnum.double;
      case Namespace0Id.string:
        return TypeKindEnum.outOfSpecContiguousString;
      case Namespace0Id.datetime:
        return TypeKindEnum.datetime;
      case Namespace0Id.guid:
        return TypeKindEnum.guid;
      case Namespace0Id.byteString:
        return TypeKindEnum.byteString;
      case Namespace0Id.xmlElement:
        return TypeKindEnum.xmlElement;
      case Namespace0Id.nodeId:
        return TypeKindEnum.nodeId;
      case Namespace0Id.expandedNodeId:
        return TypeKindEnum.expandedNodeId;
      case Namespace0Id.statusCode:
        return TypeKindEnum.statusCode;
      case Namespace0Id.qualifiedName:
        return TypeKindEnum.qualifiedName;
      case Namespace0Id.localizedText:
        return TypeKindEnum.localizedText;
      case Namespace0Id.structure:
        return TypeKindEnum.structure;
      case Namespace0Id.dataValue:
        return TypeKindEnum.dataValue;
      // case Namespace0Id.basedataType:
      //   return TypeKindEnum.basedataType;
      case Namespace0Id.diagnosticInfo:
        return TypeKindEnum.diagnosticInfo;
      default:
        throw ArgumentError('Unknown Namespace0Id value: $this');
    }
  }

  NodeId toNodeId() {
    return NodeId.fromNumeric(0, value);
  }

  UaTypes toUaTypes() {
    switch (this) {
      case Namespace0Id.boolean:
        return UaTypes.boolean;
      case Namespace0Id.sbyte:
        return UaTypes.sbyte;
      case Namespace0Id.byte:
        return UaTypes.byte;
      case Namespace0Id.int16:
        return UaTypes.int16;
      case Namespace0Id.uint16:
        return UaTypes.uint16;
      case Namespace0Id.int32:
        return UaTypes.int32;
      case Namespace0Id.uint32:
        return UaTypes.uint32;
      case Namespace0Id.int64:
        return UaTypes.int64;
      case Namespace0Id.uint64:
        return UaTypes.uint64;
      case Namespace0Id.float:
        return UaTypes.float;
      case Namespace0Id.double:
        return UaTypes.double;
      case Namespace0Id.string:
        return UaTypes.string;
      case Namespace0Id.datetime:
        return UaTypes.dateTime;
      case Namespace0Id.guid:
        return UaTypes.guid;
      case Namespace0Id.byteString:
        return UaTypes.byteString;
      case Namespace0Id.xmlElement:
        return UaTypes.xmlElement;
      case Namespace0Id.nodeId:
        return UaTypes.nodeId;
      case Namespace0Id.expandedNodeId:
        return UaTypes.expandedNodeId;
      case Namespace0Id.statusCode:
        return UaTypes.statusCode;
      case Namespace0Id.qualifiedName:
        return UaTypes.qualifiedName;
      case Namespace0Id.localizedText:
        return UaTypes.localizedText;
      case Namespace0Id.structure:
        return UaTypes.extensionObject;
      case Namespace0Id.dataValue:
        return UaTypes.dataValue;
      case Namespace0Id.diagnosticInfo:
        return UaTypes.diagnosticInfo;
      default:
        throw ArgumentError('Cannot convert Namespace0Id $this to UaTypes');
    }
  }
}

// ignore: camel_case_types
enum UaTypes {
  boolean(raw.UA_TYPES_BOOLEAN),
  sbyte(raw.UA_TYPES_SBYTE),
  byte(raw.UA_TYPES_BYTE),
  int16(raw.UA_TYPES_INT16),
  uint16(raw.UA_TYPES_UINT16),
  int32(raw.UA_TYPES_INT32),
  uint32(raw.UA_TYPES_UINT32),
  int64(raw.UA_TYPES_INT64),
  uint64(raw.UA_TYPES_UINT64),
  float(raw.UA_TYPES_FLOAT),
  double(raw.UA_TYPES_DOUBLE),
  string(raw.UA_TYPES_STRING),
  dateTime(raw.UA_TYPES_DATETIME),
  guid(raw.UA_TYPES_GUID),
  byteString(raw.UA_TYPES_BYTESTRING),
  xmlElement(raw.UA_TYPES_XMLELEMENT),
  nodeId(raw.UA_TYPES_NODEID),
  expandedNodeId(raw.UA_TYPES_EXPANDEDNODEID),
  statusCode(raw.UA_TYPES_STATUSCODE),
  qualifiedName(raw.UA_TYPES_QUALIFIEDNAME),
  localizedText(raw.UA_TYPES_LOCALIZEDTEXT),
  extensionObject(raw.UA_TYPES_EXTENSIONOBJECT),
  dataValue(raw.UA_TYPES_DATAVALUE),
  variant(raw.UA_TYPES_VARIANT),
  diagnosticInfo(raw.UA_TYPES_DIAGNOSTICINFO),
  namingRuleType(raw.UA_TYPES_NAMINGRULETYPE),
  enumeration(raw.UA_TYPES_ENUMERATION),
  imageBmp(raw.UA_TYPES_IMAGEBMP),
  imageGif(raw.UA_TYPES_IMAGEGIF),
  imageJpg(raw.UA_TYPES_IMAGEJPG),
  imagePng(raw.UA_TYPES_IMAGEPNG),
  audioDataType(raw.UA_TYPES_AUDIODATATYPE),
  uriString(raw.UA_TYPES_URISTRING),
  bitFieldMaskDataType(raw.UA_TYPES_BITFIELDMASKDATATYPE),
  semanticVersionString(raw.UA_TYPES_SEMANTICVERSIONSTRING),
  keyValuePair(raw.UA_TYPES_KEYVALUEPAIR),
  additionalParametersType(raw.UA_TYPES_ADDITIONALPARAMETERSTYPE),
  ephemeralKeyType(raw.UA_TYPES_EPHEMERALKEYTYPE),
  rationalNumber(raw.UA_TYPES_RATIONALNUMBER),
  threeDVector(raw.UA_TYPES_THREEDVECTOR),
  threeDCartesianCoordinates(raw.UA_TYPES_THREEDCARTESIANCOORDINATES),
  threeDOrientation(raw.UA_TYPES_THREEDORIENTATION),
  threeDFrame(raw.UA_TYPES_THREEDFRAME),
  openFileMode(raw.UA_TYPES_OPENFILEMODE),
  identityCriteriaType(raw.UA_TYPES_IDENTITYCRITERIATYPE),
  identityMappingRuleType(raw.UA_TYPES_IDENTITYMAPPINGRULETYPE),
  currencyUnitType(raw.UA_TYPES_CURRENCYUNITTYPE),
  trustListMasks(raw.UA_TYPES_TRUSTLISTMASKS),
  trustListDataType(raw.UA_TYPES_TRUSTLISTDATATYPE),
  decimalDataType(raw.UA_TYPES_DECIMALDATATYPE),
  dataTypeDescription(raw.UA_TYPES_DATATYPEDESCRIPTION),
  simpleTypeDescription(raw.UA_TYPES_SIMPLETYPEDESCRIPTION),
  portableQualifiedName(raw.UA_TYPES_PORTABLEQUALIFIEDNAME),
  portableNodeId(raw.UA_TYPES_PORTABLENODEID),
  unsignedRationalNumber(raw.UA_TYPES_UNSIGNEDRATIONALNUMBER),
  pubSubState(raw.UA_TYPES_PUBSUBSTATE),
  dataSetFieldFlags(raw.UA_TYPES_DATASETFIELDFLAGS),
  configurationVersionDataType(raw.UA_TYPES_CONFIGURATIONVERSIONDATATYPE),
  publishedVariableDataType(raw.UA_TYPES_PUBLISHEDVARIABLEDATATYPE),
  publishedDataItemsDataType(raw.UA_TYPES_PUBLISHEDDATAITEMSDATATYPE),
  publishedDataSetCustomSourceDataType(
      raw.UA_TYPES_PUBLISHEDDATASETCUSTOMSOURCEDATATYPE);

  final int value;
  const UaTypes(this.value);

  static UaTypes fromValue(int value) {
    return UaTypes.values.firstWhere(
      (type) => type.value == value,
      orElse: () => throw ArgumentError('Invalid UaTypes value: $value'),
    );
  }
}

// ignore: camel_case_extensions
extension UA_DataTypeExtension on raw.UA_DataType {
  int get memSize => substitute & 0xFFFF; // First 16 bits
  TypeKindEnum get typeKind =>
      TypeKindEnum.fromInt((substitute >> 16) & 0x3F); // Next 6 bits
  bool get pointerFree => ((substitute >> 22) & 0x1) == 1; // Next 1 bit
  bool get overlayable => ((substitute >> 23) & 0x1) == 1; // Next 1 bit
  int get membersSize => (substitute >> 24) & 0xFF; // Last 8 bits

  String format() {
    final nId = binaryEncodingId.format();
    final ts = typeName.cast<Utf8>().toDartString();
    final tId = typeId.format();
    final tk = typeKind;
    return 'TypeId: $tId\nTypeName: $ts\nBinaryEncodingId: $nId\nType Kind: $tk';
  }
}

// ignore: camel_case_extensions
extension UA_NodeIdExtension on raw.UA_NodeId {
  bool isNumeric() {
    return identifierType == raw.UA_NodeIdType.UA_NODEIDTYPE_NUMERIC;
  }

  bool isString() {
    return identifierType == raw.UA_NodeIdType.UA_NODEIDTYPE_STRING;
  }

  int? get numeric {
    if (identifierType == raw.UA_NodeIdType.UA_NODEIDTYPE_NUMERIC) {
      return identifier.numeric;
    }
    return null;
  }

  String? get string {
    if (identifierType == raw.UA_NodeIdType.UA_NODEIDTYPE_STRING) {
      return identifier.string.value;
    }
    return null;
  }

  NodeId toNodeId() {
    return NodeId.fromRaw(this);
  }

  String format() {
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

// ignore: camel_case_extensions
extension UA_StructureFieldExtension on raw.UA_StructureField {
  String get fieldName => name.value;
  MemberDescription get fieldDescription {
    final textValue = description.text.value;
    final localeValue = description.locale.value;
    // print('description: $textValue');
    // print('locale: $localeValue');
    return MemberDescription(textValue, localeValue);
  }

  List<int> get dimensions {
    if (arrayDimensionsSize == 0 || arrayDimensions == nullptr) {
      return [];
    }
    return arrayDimensions.asTypedList(arrayDimensionsSize);
  }
}

// ignore: camel_case_extensions
extension UA_VariantExtension on raw.UA_Variant {
  List<int> get dimensions {
    if (arrayDimensionsSize == 0 || arrayDimensions == nullptr) {
      return [];
    }
    return arrayDimensions.asTypedList(arrayDimensionsSize);
  }
}

// ignore: camel_case_extensions
extension UA_ExtensionObjectExtension on raw.UA_ExtensionObject {
  String? get encodedName {
    if (encoding !=
        raw.UA_ExtensionObjectEncoding.UA_EXTENSIONOBJECT_ENCODED_BYTESTRING) {
      return null;
    }
    final typeId = content.encoded.typeId;
    if (typeId.identifierType == raw.UA_NodeIdType.UA_NODEIDTYPE_STRING) {
      return typeId.identifier.string.value;
    }
    return null;
  }
}

void printBytes(String var_name, Uint8List bytes) {
  final buffer = StringBuffer();
  buffer.write('$var_name = [');
  for (var i = 0; i < bytes.length; i++) {
    if (i > 0) buffer.write(', ');
    buffer.write('0x${bytes[i].toRadixString(16).padLeft(2, '0')}');
  }
  buffer.write('];');
  print(buffer.toString());
}
