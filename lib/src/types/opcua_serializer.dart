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
  /// Rich schemas a server registered locally, keyed by DataType NodeId.
  ///
  /// open62541 (v1.5.x) derives a DataType node's `DataTypeDefinition`
  /// attribute from the registered custom `UA_DataType`. Its
  /// `UA_DataTypeMember` cannot store per-field descriptions or display names,
  /// and `UA_DataType_toStructureDescription` does not emit
  /// `UA_StructureField.description`, so that metadata never travels the wire.
  /// When a Dart [Server] and a [Client] share a process, the server records
  /// the full schema here via [registerLocalSchema] and
  /// [overlayLocalFieldMetadata] restores the missing field metadata on read —
  /// mirroring open62541's own "register the custom type on the client" pattern
  /// for locally-known types. A remote client simply has no entry and degrades
  /// to whatever the wire carried (an empty description).
  static final Map<NodeId, DynamicValue> _localSchemas = {};

  /// Records the [value] schema a server registered for [typeId] so field
  /// metadata that the DataTypeDefinition cannot carry (descriptions, display
  /// names) can be surfaced to an in-process client read. A defensive copy is
  /// stored so later mutation of [value] does not affect the registry.
  static void registerLocalSchema(NodeId typeId, DynamicValue value) {
    if (!value.isObject) return;
    _localSchemas[typeId] = DynamicValue.from(value);
  }

  /// The locally-registered custom-type schemas as a [Schema] (NodeId →
  /// schema tree), for decoding a structured value marshalled back into an
  /// in-process [Server] — e.g. a data-source node's write callback receives a
  /// client-written struct as a binary ExtensionObject and needs the registered
  /// field schema to restore its typed fields. Read-only view of the registry.
  static Schema get localSchemas => _localSchemas;

  /// Overlays locally-recorded field descriptions / display names for [typeId]
  /// onto [tree] (a struct schema built from a DataTypeDefinition), filling only
  /// the metadata the wire could not carry. No-op when [typeId] was not
  /// registered locally (e.g. a genuinely remote server).
  static void overlayLocalFieldMetadata(NodeId typeId, DynamicValue tree) {
    final local = _localSchemas[typeId];
    if (local == null || !local.isObject || !tree.isObject) return;
    for (final fieldName in tree.asObject.keys) {
      if (!local.asObject.containsKey(fieldName)) continue;
      final localField = local[fieldName];
      final treeField = tree[fieldName];
      final desc = treeField.description;
      if (localField.description != null && (desc == null || desc.value.isEmpty)) {
        treeField.description = localField.description;
      }
      final display = treeField.displayName;
      if (localField.displayName != null && (display == null || display.value.isEmpty)) {
        treeField.displayName = localField.displayName;
      }
    }
  }

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
      // NB: a scalar field may itself be flagged `isOptional`; its presence is
      // decided by the struct-level encoding mask (see the object branch), so
      // by the time we reach here the field is known to be present and is
      // decoded like any other scalar.
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
      final fields = schema.asObject;
      final hasOptional = fields.values.any((f) => f.isOptional);
      if (!hasOptional) {
        for (final key in fields.keys.toList()) {
          fields[key] = OpcUaDynamicValueSerializer.deserialize(fields[key]!, bodyReader, endian, true);
        }
      } else {
        // OPC UA Part 6 / open62541 decodeBinaryStructureWithOptFields: a struct
        // with optional fields is prefixed by a UInt32 encoding mask. Bit `o`
        // (counted over the OPTIONAL fields only, in declaration order) is set
        // when the o-th optional field is present. Required fields are always
        // decoded; an optional field is decoded only when its bit is set,
        // otherwise it is left absent (value null).
        final mask = bodyReader.uint32(endian);
        int o = 0;
        for (final key in fields.keys.toList()) {
          final field = fields[key]!;
          if (!field.isOptional) {
            fields[key] = OpcUaDynamicValueSerializer.deserialize(field, bodyReader, endian, true);
            continue;
          }
          final present = (mask & (1 << o)) != 0;
          o++;
          if (present) {
            fields[key] = OpcUaDynamicValueSerializer.deserialize(field, bodyReader, endian, true);
          } else {
            // Absent optional field: leave it null so callers can distinguish it.
            field.value = null;
          }
        }
      }
    }

    // We are a array case
    if (schema.isArray) {
      // Read the size of the stack to increment the
      // read pointer but only if we are not the root
      if (!root) {
        final arrayLength = reader.int32(endian);
        // A struct's array member carries its length on the wire, not in the
        // DataTypeDefinition schema (which only knows the field is an array and
        // was seeded with a single template element). Grow/shrink the schema
        // array to the wire length by cloning that template so every element can
        // be deserialized against the correct type.
        if (arrayLength != schema.asArray.length) {
          if (schema.asArray.isEmpty) {
            throw 'Cannot size array member of length $arrayLength: schema has no template element';
          }
          final template = schema.asArray.first;
          schema.value = <DynamicValue>[for (var i = 0; i < arrayLength; i++) DynamicValue.from(template)];
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
      _serializeStructBody(value, bodyWriter, endian);
      obj.ref.content.encoded.body.fromBytes(bodyWriter.toBytes());
      // todo support other encodings
      obj.ref.encodingAsInt = raw.UA_ExtensionObjectEncoding.UA_EXTENSIONOBJECT_ENCODED_BYTESTRING.value;
      // write the extension object to the writer
      final extObjView = obj.cast<ffi.Uint8>().asTypedList(ffi.sizeOf<raw.UA_ExtensionObject>());
      // here we have made a view into the ext object on the C heap
      // I would like to believe that this is freed when the variant is freed
      writer.write(extObjView);
    } else if (value.isObject) {
      _serializeStructBody(value, writer, endian);
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

  /// Serialize the members of a struct [struct] into [writer].
  ///
  /// OPC UA Part 6: a structure that declares one or more OPTIONAL fields is
  /// encoded with a leading UInt32 "encoding mask". Bit `o` (counted over the
  /// OPTIONAL fields only, in declaration order) is set when the o-th optional
  /// field is present (non-null value). Required fields are always encoded; an
  /// optional field is encoded only when its bit is set. This mirrors
  /// open62541's `encodeBinaryStructWithOptFields`
  /// (src/ua_types_encoding_binary.c). A struct with no optional fields is
  /// encoded without any mask, exactly as before.
  static void _serializeStructBody(DynamicValue struct, ByteWriter writer, Endian? endian) {
    final fields = struct.asObject.values.toList(growable: false);
    final hasOptional = fields.any((f) => f.isOptional);
    if (!hasOptional) {
      for (final f in fields) {
        OpcUaDynamicValueSerializer.serialize(f, writer, f, endian, true);
      }
      return;
    }
    int mask = 0;
    int o = 0;
    for (final f in fields) {
      if (!f.isOptional) continue;
      if (!f.isNull) mask |= 1 << o;
      o++;
    }
    writer.uint32(mask, endian);
    for (final f in fields) {
      // Skip absent optional fields; required fields and present optional
      // fields are always encoded, in declaration order.
      if (f.isOptional && f.isNull) continue;
      OpcUaDynamicValueSerializer.serialize(f, writer, f, endian, true);
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

        // open62541 flags an array member with valueRank ONE_DIMENSION (1) and a
        // single arrayDimensions entry whose value is 0 (see
        // UA_DataType_toStructureDefinition): the definition records only *that*
        // the field is an array, never its runtime length, which is carried on
        // the wire as an int32 prefix inside the struct body. Seed the field with
        // a single template element; the deserializer clones it to match the
        // length it reads from the buffer.
        final isArrayField = field.dimensions.isNotEmpty || field.valueRank >= raw.UA_VALUERANK_ONE_DIMENSION;
        if (!isArrayField) {
          tree[fieldName] = DynamicValue(typeId: fieldDataType);
        } else {
          tree[fieldName] = DynamicValue.fromList([DynamicValue(typeId: fieldDataType)], typeId: fieldDataType);
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
