// UaTypeMismatch is a UaStatusException, so a consumer that classifies errors
// by their status code sees it as the code it carries. That code has to be
// Bad_TypeMismatch: 0x80730000, one below it, is Bad_WriteNotSupported, and a
// consumer reading that reports a configuration fault as something else.

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;

void main() {
  final mismatch = UaTypeMismatch(
    expected: NodeId.fromNumeric(0, 12), // String
    actual: NodeId.fromNumeric(0, 14), // Guid
  );

  test('carries Bad_TypeMismatch as its status code', () {
    expect(mismatch.statusCode, raw.UA_STATUSCODE_BADTYPEMISMATCH);
    expect(mismatch.statusCode, isNot(raw.UA_STATUSCODE_BADWRITENOTSUPPORTED));
  });

  test('names the status in its message, as UaStatusException does', () {
    expect(mismatch.toString(), contains(statusCodeToString(raw.UA_STATUSCODE_BADTYPEMISMATCH)));
    expect(mismatch.toString(), contains('typed ${mismatch.expected}'));
    expect(mismatch.toString(), contains('carries ${mismatch.actual}'));
  });
}
