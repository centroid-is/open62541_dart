@TestOn('linux')
library;

import 'dart:io';

import 'package:test/test.dart';

import 'package:open62541/src/third_party/open62541.g.dart' as raw;

// Runs only in the sanitizer lane, where an empty `.open62541_sanitizer` file in
// the package root makes hook/build.dart compile the library with ASan + UBSan.
// It checks that the library the VM loaded really carries the instrumentation,
// so the lane cannot go green against a plain build again.
void main() {
  final enabled = File('.open62541_sanitizer').existsSync();

  test('libopen62541.so is built with AddressSanitizer', () async {
    raw.UA_StatusCode_name(raw.UA_STATUSCODE_GOOD);
    String? library;
    for (final line in File('/proc/self/maps').readAsLinesSync()) {
      if (line.contains('/') && line.endsWith('/libopen62541.so')) {
        library = line.substring(line.indexOf('/'));
        break;
      }
    }
    expect(library, isNotNull, reason: 'libopen62541.so is not mapped into this process');
    final nm = await Process.run('nm', ['-D', library!]);
    expect(nm.stdout as String, contains('__asan_init'), reason: 'no ASan runtime import in $library');
  }, skip: enabled ? false : 'needs a .open62541_sanitizer file in the package root');
}
