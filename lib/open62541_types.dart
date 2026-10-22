/// The pure-Dart value types of `package:open62541`, with no `dart:ffi`.
///
/// [DynamicValue] is the type every HMI widget speaks, and until this barrel
/// existed reaching it meant reaching `dart:ffi` through `node_id.dart` — which
/// makes a Flutter web build a hard compile error, not a runtime one. Import
/// this file from code that must also run in a browser; import
/// `open62541.dart` from anything that talks to a real OPC UA server.
///
/// Anything exported here is verified to compile under dart2js by
/// `test/web/types_web_test.dart`.
library;

export 'src/dynamic_value.dart' show DynamicValue, DynamicType, LocalizedText, EnumField, Schema;
export 'src/node_id_core.dart' show NodeId;
