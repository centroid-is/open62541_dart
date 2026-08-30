import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/common.dart';
import 'package:open62541/src/extensions.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;

void main() {
  test("Verify sizes", () {
    // UA_ClientConfig is unchanged by enabling PubSub (the PubSub subscriber
    // hangs off UA_Server, not UA_Client).
    expect(sizeOf<raw.UA_ClientConfig>(), 888);
    expect(sizeOf<raw.UA_DataType>(), 96);
    // UA_ServerConfig grew with UA_ENABLE_PUBSUB (it now embeds the
    // UA_PubSubConfiguration). Pin the layout of the config structs the Dart
    // wrappers fill so a bindings/native drift fails loudly here rather than
    // as memory corruption.
    expect(sizeOf<raw.UA_ServerConfig>(), 1184);
    expect(sizeOf<raw.UA_PubSubConnectionConfig>(), 192);
    expect(sizeOf<raw.UA_WriterGroupConfig>(), 224);
    expect(sizeOf<raw.UA_DataSetReaderConfig>(), 376);
  });
  test("Verify types", () {
    expect(getType(UaTypes.boolean).ref.typeName.cast<Utf8>().toDartString(), "Boolean");
    expect(getType(UaTypes.readRequest).ref.typeName.cast<Utf8>().toDartString(), "ReadRequest");
    expect(getType(UaTypes.readResponse).ref.typeName.cast<Utf8>().toDartString(), "ReadResponse");
    expect(getType(UaTypes.boolean).ref.typeName.cast<Utf8>().toDartString(), "Boolean");
  });
}
