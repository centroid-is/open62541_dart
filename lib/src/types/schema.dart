import '../extensions.dart';
import 'package:binarize/binarize.dart';
import 'package:collection/collection.dart';
import '../../dynamic_value.dart';
import '../nodeId.dart';

class StructureSchema extends PayloadType<DynamicValue> {
  static const schemaRootId = '__root';

  final NodeId nodeIdType;
  final String fieldName;
  List<StructureSchema> fields = [];
  final PayloadType? elementType;

  StructureSchema(NodeId nodeId, this.fieldName,
      [this.elementType, List<StructureSchema>? fields])
      : nodeIdType = nodeId,
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
      for (var i = 0; i < fields.length; i++) {
        fields[i].set(writer, value[fields[i].fieldName], endian);
      }
    } else {
      if (elementType == null) {
        throw StateError(
            'Element type is not set for $nodeIdType where value is\n $value');
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
    return types.firstWhereOrNull((type) => type.nodeIdType.string == name);
  }

  bool contains(String name) {
    name = name.replaceAll('__DefaultBinary', ''); // this okay?
    return types.any((type) => type.nodeIdType.string == name);
  }
}
