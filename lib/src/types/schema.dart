import '../extensions.dart';
import 'package:binarize/binarize.dart';
import 'package:collection/collection.dart';
import '../../dynamic_value.dart';
import '../nodeId.dart';

class _IdType {
  final String? stringId;
  final int? numericId;

  _IdType.fromNodeId(NodeId nodeId)
      : stringId = nodeId.isString() ? nodeId.string : null,
        numericId = nodeId.isNumeric() ? nodeId.numeric : null {
    if (!nodeId.isString() && !nodeId.isNumeric()) {
      throw FormatException('NodeId must be either string or numeric');
    }
  }

  bool isString() => stringId != null;
  bool isNumeric() => numericId != null;

  @override
  String toString() {
    if (isString()) return 'string:$stringId';
    if (isNumeric()) return 'numeric:$numericId';
    return 'invalid';
  }
}

class StructureSchema extends PayloadType<DynamicValue> {
  final _IdType nodeIdType;
  final String fieldName;
  List<StructureSchema> fields = [];
  final PayloadType? elementType;

  StructureSchema(NodeId nodeId, this.fieldName,
      [this.elementType, List<StructureSchema>? fields])
      : nodeIdType = _IdType.fromNodeId(nodeId),
        fields = fields ?? [];

  @override
  DynamicValue get(ByteReader reader, [Endian? endian]) {
    DynamicValue result = DynamicValue(nodeIdType.toString());
    if (elementType != null) {
      result.value = elementType!.get(reader, endian);
    }
    for (var field in fields) {
      result[field.fieldName] = field.get(reader, endian);
    }
    return result;
  }

  @override
  void set(ByteWriter writer, DynamicValue value, [Endian? endian]) {
    if (value.isObject) {
      for (var entry in value.entries) {
        set(writer, entry.value, endian);
      }
    } else if (value.isArray) {
      for (var entry in value.asArray) {
        set(writer, entry, endian);
      }
    } else {
      if (elementType == null) {
        throw StateError('Element type is not set');
      }
      elementType!.set(writer, value.asDynamic, endian);
    }
  }

  @override
  String toString() {
    try {
      final fieldsStr = fields.isEmpty
          ? 'fields: []'
          : '''fields: [
${fields.map((f) => _formatField(f, 1)).join(',\n')}
  ]''';

      return '''StructureSchema(
  nodeIdType: $nodeIdType,
  elementType: ${_formatElementType(elementType)},
  $fieldsStr
)''';
    } catch (e) {
      return 'StructureSchema(<format error>)';
    }
  }

  String _formatField(StructureSchema field, int depth) {
    final indent = '  ' * (depth + 1);
    final fieldStr = '''$indent{
$indent  type: ${field.nodeIdType},
$indent  payload: ${_formatElementType(field.elementType)}${field.fields.isEmpty ? '' : ','}${field.fields.isEmpty ? '' : '''
$indent  fields: [
${field.fields.map((f) => _formatField(f, depth + 1)).join(',\n')}
$indent  ]'''}
$indent}''';
    return fieldStr;
  }

  String _formatElementType(PayloadType? type) {
    if (type == null) return 'null';
    return type.toString().split('.').last.replaceAll('Payload', '');
  }

  void addField(StructureSchema field) {
    fields.add(field);
  }
}

class KnownStructures {
  List<StructureSchema> types = [];

  void add(StructureSchema type) {
    types.add(type);
  }

  StructureSchema? get(String name) {
    name = name.replaceAll('__DefaultBinary', ''); // this okay?
    return types.firstWhereOrNull((type) => type.nodeIdType.stringId == name);
  }

  bool contains(String name) {
    return types.any((type) => type.nodeIdType.stringId == name) ||
        types.any(
            (type) => type.nodeIdType.stringId == "${name}__DefaultBinary");
  }
}
