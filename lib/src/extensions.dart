import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'dynamic_value.dart';
import 'generated/open62541_bindings.dart' as raw;
import 'node_id.dart';

typedef MonitoringMode = raw.UA_MonitoringMode;
typedef AttributeId = raw.UA_AttributeId;
typedef MessageSecurityMode = raw.UA_MessageSecurityMode;
typedef SessionState = raw.UA_SessionState;
typedef SecureChannelState = raw.UA_SecureChannelState;

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
  references(raw.UA_NS0ID_REFERENCES),
  structureDefinition(raw.UA_NS0ID_STRUCTUREDEFINITION),
  structureDefinitionDefaultBinary(raw.UA_NS0ID_STRUCTUREDEFINITION_ENCODING_DEFAULTBINARY),
  enumDefinitionDefaultBinary(raw.UA_NS0ID_ENUMDEFINITION_ENCODING_DEFAULTBINARY);

  final int value;
  const Namespace0Id(this.value);

  static Namespace0Id fromInt(int value) {
    return Namespace0Id.values.firstWhere(
      (id) => id.value == value,
      orElse: () => throw ArgumentError('Unknown Namespace0Id value: $value'),
    );
  }

  raw.UA_DataTypeKind toDataTypeKind() {
    switch (this) {
      case Namespace0Id.boolean:
        return raw.UA_DataTypeKind.UA_DATATYPEKIND_BOOLEAN;
      case Namespace0Id.sbyte:
        return raw.UA_DataTypeKind.UA_DATATYPEKIND_SBYTE;
      case Namespace0Id.byte:
        return raw.UA_DataTypeKind.UA_DATATYPEKIND_BYTE;
      case Namespace0Id.int16:
        return raw.UA_DataTypeKind.UA_DATATYPEKIND_INT16;
      case Namespace0Id.uint16:
        return raw.UA_DataTypeKind.UA_DATATYPEKIND_UINT16;
      case Namespace0Id.int32:
        return raw.UA_DataTypeKind.UA_DATATYPEKIND_INT32;
      case Namespace0Id.uint32:
        return raw.UA_DataTypeKind.UA_DATATYPEKIND_UINT32;
      case Namespace0Id.int64:
        return raw.UA_DataTypeKind.UA_DATATYPEKIND_INT64;
      case Namespace0Id.uint64:
        return raw.UA_DataTypeKind.UA_DATATYPEKIND_UINT64;
      case Namespace0Id.float:
        return raw.UA_DataTypeKind.UA_DATATYPEKIND_FLOAT;
      case Namespace0Id.double:
        return raw.UA_DataTypeKind.UA_DATATYPEKIND_DOUBLE;
      case Namespace0Id.string:
        return raw.UA_DataTypeKind.UA_DATATYPEKIND_STRING;
      case Namespace0Id.datetime:
        return raw.UA_DataTypeKind.UA_DATATYPEKIND_DATETIME;
      case Namespace0Id.guid:
        return raw.UA_DataTypeKind.UA_DATATYPEKIND_GUID;
      case Namespace0Id.byteString:
        return raw.UA_DataTypeKind.UA_DATATYPEKIND_BYTESTRING;
      case Namespace0Id.xmlElement:
        return raw.UA_DataTypeKind.UA_DATATYPEKIND_XMLELEMENT;
      case Namespace0Id.nodeId:
        return raw.UA_DataTypeKind.UA_DATATYPEKIND_NODEID;
      case Namespace0Id.expandedNodeId:
        return raw.UA_DataTypeKind.UA_DATATYPEKIND_EXPANDEDNODEID;
      case Namespace0Id.statusCode:
        return raw.UA_DataTypeKind.UA_DATATYPEKIND_STATUSCODE;
      case Namespace0Id.qualifiedName:
        return raw.UA_DataTypeKind.UA_DATATYPEKIND_QUALIFIEDNAME;
      case Namespace0Id.localizedText:
        return raw.UA_DataTypeKind.UA_DATATYPEKIND_LOCALIZEDTEXT;
      case Namespace0Id.structure:
        return raw.UA_DataTypeKind.UA_DATATYPEKIND_STRUCTURE;
      case Namespace0Id.dataValue:
        return raw.UA_DataTypeKind.UA_DATATYPEKIND_DATAVALUE;
      // case Namespace0Id.basedataType:
      //   return TypeKindEnum.basedataType;
      case Namespace0Id.diagnosticInfo:
        return raw.UA_DataTypeKind.UA_DATATYPEKIND_DIAGNOSTICINFO;
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
  publishedDataSetCustomSourceDataType(raw.UA_TYPES_PUBLISHEDDATASETCUSTOMSOURCEDATATYPE),
  readRequest(raw.UA_TYPES_READREQUEST),
  readResponse(raw.UA_TYPES_READRESPONSE);

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
  raw.UA_DataTypeKind get typeKind => raw.UA_DataTypeKind.fromValue((substitute >> 16) & 0x3F); // Next 6 bits
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

  void fromNodeId(NodeId nodeId) {
    namespaceIndex = nodeId.namespace;
    if (nodeId.isNumeric()) {
      identifierTypeAsInt = raw.UA_NodeIdType.UA_NODEIDTYPE_NUMERIC.value;
      identifier.numeric = nodeId.numeric;
    } else if (nodeId.isString()) {
      identifierTypeAsInt = raw.UA_NodeIdType.UA_NODEIDTYPE_STRING.value;
      identifier.string.set(nodeId.string);
    } else {
      throw ArgumentError('Invalid NodeId type: $nodeId');
    }
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
extension UA_StructFieldFormat on raw.UA_StructureDefinition {
  String format() {
    try {
      var fstr = '';
      for (int i = 0; i < fields.ref.dimensions.length; i++) {
        fstr += _formatField(fields[i], 1);
      }
      final fieldsStr = fields.ref.dimensions.isEmpty
          ? 'fields: []'
          : '''fields: [
          $fstr
  ]''';

      return '''StructureSchema(
  NodeId: ${baseDataType.format()},
  $fieldsStr
)''';
    } catch (e) {
      return 'StructureSchema(<format error>)';
    }
  }

  String _formatField(raw.UA_StructureField field, int depth) {
    final indent = '  ' * (depth + 1);
    final fieldStr = '''$indent{
$indent  structureName: ${field.name.value},
$indent  name: ${field.fieldName},
$indent  NodeId: ${field.dataType.format()}${field.dimensions.isEmpty ? '' : ','}${field.dimensions.isEmpty ? '' : '''
$indent  ]'''}
$indent}''';
    return fieldStr;
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

  void fromBytes(Iterable<int> bytes) {
    free();
    data = calloc(bytes.length);
    // memcpy as fast as possible
    data.asTypedList(bytes.length).setRange(0, bytes.length, bytes);
    length = bytes.length;
  }

  Uint8List asTypedList() => data.asTypedList(length);

  void free() {
    if (data != nullptr) {
      calloc.free(data);
      data = nullptr;
      length = 0;
    }
  }
}

extension LocalizedTextExtension on raw.UA_LocalizedText {
  LocalizedText get localizedText {
    return LocalizedText(text.value, locale.value);
  }
}

// ignore: camel_case_extensions
extension UA_StructureFieldExtension on raw.UA_StructureField {
  String get fieldName => name.value;

  List<int> get dimensions {
    if (arrayDimensionsSize == 0 || arrayDimensions == nullptr) {
      return [];
    }
    return arrayDimensions.asTypedList(arrayDimensionsSize);
  }
}

// ignore: camel_case_extensions
extension UA_VariantExtension on raw.UA_Variant {
  // please note that the memory for the return type is freed
  // when the variant is freed
  List<int> get dimensions {
    if (arrayDimensionsSize == 0 || arrayDimensions == nullptr) {
      // single dimension
      if (arrayLength > 0) {
        return [arrayLength];
      }
      return [];
    }
    // multi dimension
    return arrayDimensions.asTypedList(arrayDimensionsSize);
  }

  String format() {
    String mytype = type == nullptr ? "" : type.ref.format();
    return "Type: $mytype\n StorageType: $storageType\n ArrayLength: $arrayLength";
  }
}

// ignore: camel_case_extensions
extension UA_ExtensionObjectExtension on raw.UA_ExtensionObject {
  String? get encodedName {
    if (encoding != raw.UA_ExtensionObjectEncoding.UA_EXTENSIONOBJECT_ENCODED_BYTESTRING) {
      return null;
    }
    final typeId = content.encoded.typeId;
    if (typeId.identifierType == raw.UA_NodeIdType.UA_NODEIDTYPE_STRING) {
      return typeId.identifier.string.value;
    }
    return null;
  }
}

void printBytes(TypedData bytes) {
  final buffer = StringBuffer();
  buffer.write('var data = [');
  for (var i = 0; i < bytes.lengthInBytes; i++) {
    if (i > 0) buffer.write(', ');
    buffer.write('0x${bytes.buffer.asUint8List()[i].toRadixString(16).padLeft(2, '0')}');
  }
  buffer.write('];');
  print(buffer.toString());
}
