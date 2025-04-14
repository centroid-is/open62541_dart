import 'package:binarize/binarize.dart';
import 'package:collection/collection.dart';
import '../../dynamic_value.dart';

class StructureSchema extends PayloadType<DynamicValue> {
  static const schemaRootId = '__root';

  final String? structureName;
  final String fieldName;
  MemberDescription? description;
  List<StructureSchema> fields = [];
  final PayloadType? elementType;
  // this would be nice to have, assert that the reader/writer length is the same as the schema
  // could fail faster
  // int size = 0;

  StructureSchema(this.fieldName,
      {this.elementType,
      this.structureName,
      List<StructureSchema>? fields,
      this.description})
      : fields = fields ?? [];

  @override
  DynamicValue get(ByteReader reader, [Endian? endian]) {
    if (elementType != null) {
      return DynamicValue(
          value: elementType!.get(reader, endian), description: description);
    }
    DynamicValue result = DynamicValue(description: description);
    for (final field in fields) {
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
            'Element type is not set for $fieldName where value is\n $value');
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
  structureName: ${structureName ?? 'null'},
  fieldName: $fieldName,
  description: ${description?.value ?? 'null'},
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
$indent  structureName: ${field.structureName ?? 'null'},
$indent  name: ${field.fieldName},
$indent  description: ${field.description?.value ?? 'null'},
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
    return types.firstWhereOrNull((type) => type.structureName == name);
  }

  bool contains(String name) {
    name = name.replaceAll('__DefaultBinary', ''); // this okay?
    return types.any((type) => type.structureName == name);
  }
}
