import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'heap_growth.dart';

/// Regression tests for native memory a [Client] allocated and never freed.
/// Each repeats one operation that must leave the C heap as it found it, see
/// heap_growth.dart.
void main() {
  test('a client with a username and password leaves nothing on the C heap once deleted', () async {
    // Long credentials, so that the two strings stand out against the rest of
    // a client's life: delete() takes 10 ms, which leaves few clients per round.
    final username = 'u' * 2000;
    final password = 'p' * 3000;
    await expectNoHeapGrowth(
      () => Client(username: username, password: password, logLevel: LogLevel.UA_LOGLEVEL_FATAL).delete(),
      warmUp: 20,
      iterations: 10,
      rounds: 7,
      maxGrowth: 1000,
      attempts: 3,
    );
  });
}
