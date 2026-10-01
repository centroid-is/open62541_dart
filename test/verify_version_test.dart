import 'dart:ffi';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/extensions.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'package:open62541/src/ua_allocation.dart';

void main() {
  test('Verify version', () {
    expect(UA_OPEN62541_VERSION, "v1.5.8");
  });

  // UA_OPEN62541_VERSION is a constant baked into the generated bindings, so
  // the test above cannot tell which library was actually built. The default
  // server config carries the version the native library was compiled as.
  test('Native library matches the bindings version', () {
    final config = ua_calloc<raw.UA_ServerConfig>();
    expect(raw.UA_ServerConfig_setMinimal(config, 4840, nullptr), raw.UA_STATUSCODE_GOOD);
    final server = raw.UA_Server_newWithConfig(config);
    ua_calloc.free(config);
    addTearDown(() => raw.UA_Server_delete(server));

    final nativeVersion = raw.UA_Server_getConfig(server).ref.buildInfo.softwareVersion.value;
    expect('v$nativeVersion', UA_OPEN62541_VERSION);
  });
}
