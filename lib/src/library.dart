import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'generated/open62541_bindings.dart' as raw;

class Open62541 {
  late raw.open62541 _lib;
  static Uri? _objectPath() {
    var ending = 'so';
    if (Platform.isMacOS) {
      ending = 'dylib';
    } else if (Platform.isWindows) {
      ending = 'dll';
    }
    return Isolate.resolvePackageUriSync(Uri.parse('package:open62541/libopen62541.$ending'));
  }

  Open62541() {
    var path = _objectPath();
    if (path == null) {
      throw Exception('Could not resolve package path');
    }
    _lib = raw.open62541(DynamicLibrary.open(path.path));
  }
  raw.open62541 get lib => _lib;
}

class Open62541Singleton {
  static final _instance = Open62541Singleton._internal();
  final Open62541 _lib = Open62541();

  factory Open62541Singleton() {
    return _instance;
  }
  raw.open62541 get lib => _lib.lib;
  Open62541Singleton._internal();
}

// TODO: Just store this here
// Can hopefully be injected into the class
String toString(raw.UA_String str) {
  return utf8.decode(str.data.asTypedList(str.length));
}

// raw.UA_String toUAString(String str) {
//   raw.UA_String ret = raw.UA_String.allocate();
//   ret.data = str.toNativeUtf8().cast();
//   ret.length = str.length;
//   return ret;
// }

// TODO: Create an enum for statusCodes and use it.
