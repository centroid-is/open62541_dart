import 'dart:ffi' as ffi;

import 'package:binarize/binarize.dart';

import 'package:open62541/src/extensions.dart';
import '../dynamic_value.dart';
import '../node_id.dart';
import '../third_party/open62541.g.dart' as raw;
import '../ua_allocation.dart';
import 'create_type.dart';
import 'payloads.dart';

/// OPC UA specific serializer for DynamicValue.
///
/// Extracts the OPC UA binary serialization logic that was previously
/// embedded in DynamicValue (via `PayloadType<DynamicValue>` inheritance).
/// This allows DynamicValue to remain a protocol-agnostic data container
/// while OPC UA serialization is handled externally.
class OpcUaDynamicValueSerializer {
  /// Deserialize binary data into a DynamicValue tree.
  ///
  /// Replaces the former DynamicValue.get() method.
  /// Mutates [schema] in-place and returns it.
  static DynamicValue deserialize(
    DynamicValue schema,
    ByteReader reader, [
    Endian? endian,
    bool insideStruct = false,
    bool root = false,
  ]) {
    // Assume we are in a structure of DynamicValue where typeId is set but all values are null
    // {
    // { }
    // [DynamicValue([DynamicValue(null, typeId)], )]
    // }
    // Trivial case ( bool, int, etc )
    if (!schema.isArray && !schema.isObject) {
      if (schema.isOptional) {
        throw 'Optional values not supported currently';
      }
      // Special case for strings, encoded differently for structs here then UA_String
      if (schema.typeId == NodeId.uastring && insideStruct) {
        schema.value = ContiguousStringPayload().get(reader, endian);
      } else {
        final pload = nodeIdToPayloadType(schema.typeId);
        if (pload == null) {
          throw 'Unsupported typeId: ${schema.typeId}';
        }
        schema.value = pload.get(reader, endian);
      }
    }

    // We are a object case
    if (schema.isObject) {
      ByteReader bodyReader = reader;
      if (root) {
        final objBytes = reader.read(ffi.sizeOf<raw.UA_ExtensionObject>());
        ffi.Pointer<raw.UA_ExtensionObject> obj = ua_calloc();
        obj
            .cast<ffi.Uint8>()
            .asTypedList(ffi.sizeOf<raw.UA_ExtensionObject>())
            .setRange(0, ffi.sizeOf<raw.UA_ExtensionObject>(), objBytes);
        // Todo only support encoded byte string for now
        assert(obj.ref.encoding == raw.UA_ExtensionObjectEncoding.UA_EXTENSIONOBJECT_ENCODED_BYTESTRING);
        final bodyBytes = obj.ref.content.encoded.body.asTypedList();
        bodyReader = ByteReader(bodyBytes, endian: endian ?? Endian.little);
      }
      for (final key in schema.value.keys) {
        schema.value[key] = OpcUaDynamicValueSerializer.deserialize(schema.value[key], bodyReader, endian, true);
      }
    }

    // We are a array case
    if (schema.isArray) {
      // Read the size of the stack to increment the
      // read pointer but only if we are not the root
      if (!root) {
        final arrayLength = reader.int32(endian);
        if (arrayLength != schema.asArray.length) {
          throw 'Structure definition and array length from buffer dont match';
        }
      }
      for (int i = 0; i < schema.asArray.length; i++) {
        // if array is root and subsequent type is array we should treat that also as root
        // as in not read the subsequent array length
        schema.value[i] = OpcUaDynamicValueSerializer.deserialize(schema.value[i], reader, endian, insideStruct, root);
      }
    }
    return schema;
  }

  /// Serialize a DynamicValue tree into binary data.
  ///
  /// Replaces the former DynamicValue.set() method.
  static void serialize(
    DynamicValue schema,
    ByteWriter writer,
    DynamicValue value, [
    Endian? endian,
    bool insideStruct = false,
    bool root = false,
  ]) {
    if (value.isArray) {
      // Don't encode the array length if we are the root
      if (!root) {
        writer.int32(value.value.length, endian);
      }
      for (var i = 0; i < value.value.length; i++) {
        // if array is root and subsequent type is array we should treat that also as root
        // as in not read the subsequent array length
        OpcUaDynamicValueSerializer.serialize(value.value[i], writer, value.value[i], endian, insideStruct, root);
      }
    } else if (value.isObject && root) {
      ffi.Pointer<raw.UA_ExtensionObject> obj = ua_calloc<raw.UA_ExtensionObject>();
      obj.ref.content.encoded.typeId.fromNodeId(value.extObjEncodingId ?? value.typeId!);
      ByteWriter bodyWriter = ByteWriter();
      value.value.forEach((key, val) => OpcUaDynamicValueSerializer.serialize(val, bodyWriter, val, endian, true));
      obj.ref.content.encoded.body.fromBytes(bodyWriter.toBytes());
      // todo support other encodings
      obj.ref.encodingAsInt = raw.UA_ExtensionObjectEncoding.UA_EXTENSIONOBJECT_ENCODED_BYTESTRING.value;
      // write the extension object to the writer
      final extObjView = obj.cast<ffi.Uint8>().asTypedList(ffi.sizeOf<raw.UA_ExtensionObject>());
      // here we have made a view into the ext object on the C heap
      // I would like to believe that this is freed when the variant is freed
      writer.write(extObjView);
    } else if (value.isObject) {
      value.value.forEach((key, val) => OpcUaDynamicValueSerializer.serialize(val, writer, val, endian, true));
    } else {
      if (value.isNull) {
        throw StateError('Element type is not set for where value is\n $value');
      }
      //Special case for strings, they are different the UA_Strings when
      // encoded inside of a struct
      if (schema.typeId == NodeId.uastring && insideStruct) {
        ContiguousStringPayload().set(writer, value.value, endian);
      } else {
        nodeIdToPayloadType(value.typeId ?? _autoDeduceType(value.value))!.set(writer, value.value, endian);
      }
    }
  }

  /// Build DynamicValue schema from OPC UA data type definition.
  ///
  /// Replaces the former DynamicValue.fromDataTypeDefinition() factory.
  static DynamicValue fromDataTypeDefinition(NodeId typeId, raw.UA_Variant def) {
    DynamicValue tree = DynamicValue(typeId: typeId);

    // If we know how to deal with this type
    if (nodeIdToPayloadType(typeId) != null) {
      return tree;
    }

    // Check if we are an enum
    final binaryEncodingId = def.type.ref.binaryEncodingId.toNodeId();
    if (binaryEncodingId == NodeId.enumDefinitionDefaultBinary) {
      final enumDefinition = def.data.cast<raw.UA_EnumDefinition>();
      final enumFields = <int, EnumField>{};
      for (int i = 0; i < enumDefinition.ref.fieldsSize; i++) {
        final field = enumDefinition.ref.fields[i];
        enumFields[field.value] = EnumField(
          field.value,
          field.name.value,
          field.displayName.localizedText,
          field.description.localizedText,
        );
      }
      tree.enumFields = enumFields;
      //TODO: This only supports int32 enums for now
      tree.typeId = NodeId.int32;
    } else if (binaryEncodingId == NodeId.structureDefinitionDefaultBinary) {
      final structSchema = def.data.cast<raw.UA_StructureDefinition>();
      // Object case & Array case
      for (int i = 0; i < structSchema.ref.fieldsSize; i++) {
        final field = structSchema.ref.fields[i];
        final fieldName = field.fieldName;
        final fieldDataType = field.dataType.toNodeId();

        if (field.dimensions.isEmpty) {
          tree[fieldName] = DynamicValue(typeId: fieldDataType);
        } else {
          // Don't support multi dimensional fields for now
          assert(field.dimensions.length == 1);
          var collection = [];
          for (int i = 0; i < field.dimensions[0]; i++) {
            collection.add(DynamicValue(typeId: fieldDataType));
          }
          tree[fieldName] = DynamicValue.fromList(collection, typeId: fieldDataType);
        }
        tree[fieldName].isOptional = field.isOptional;
        tree[fieldName].description = field.description.localizedText;
        tree[fieldName].name = field.name.value;
      }
    } else {
      throw 'Unsupported binary encoding id: $binaryEncodingId for AttributeId UA_ATTRIBUTEID_DATATYPEDEFINITION';
    }
    // Need description and displayname for the root
    return tree;
  }

  /// Maps Dart types to OPC UA NodeId constants for auto type deduction.
  ///
  /// Extracted from the former DynamicValue._autoDeduceType() method.
  static NodeId _autoDeduceType(dynamic data) {
    if (data is bool) return NodeId.boolean;
    if (data is String) return NodeId.uastring;
    if (data is int) throw 'Unable to auto deduce type';
    throw 'Unable to deduce type ${data.runtimeType} for $data';
  }
}
