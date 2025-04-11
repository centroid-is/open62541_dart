import 'package:test/test.dart';
import 'package:binarize/binarize.dart';

import 'package:open62541_bindings/src/types/payloads.dart';

void main() {
  test('DateTime payload', () {
    final payload = UA_DateTimePayload();

    // Test a known date/time value
    final writer = ByteWriter();
    final originalDate = DateTime(2024, 3, 14, 15, 9, 26, 535);
    payload.set(writer, originalDate);

    final reader = ByteReader(writer.toBytes());
    final convertedDate = payload.get(reader);

    expect(convertedDate, originalDate);
    expect(convertedDate.millisecondsSinceEpoch,
        originalDate.millisecondsSinceEpoch);

    // Test specific components
    expect(convertedDate.year, 2024);
    expect(convertedDate.month, 3);
    expect(convertedDate.day, 14);
    expect(convertedDate.hour, 15);
    expect(convertedDate.minute, 9);
    expect(convertedDate.second, 26);
    expect(convertedDate.millisecond, 535);
  });
}
