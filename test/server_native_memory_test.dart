import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'heap_growth.dart';

/// Regression tests for native memory a [Server] allocated and never freed.
/// Each repeats one operation that must leave the C heap as it found it, see
/// heap_growth.dart.
///
/// No server here is started: creating one and adding nodes to it needs no
/// listening socket, so nothing depends on a port.
void main() {
  test('a server leaves nothing on the C heap once deleted', () async {
    // Creating a server builds the whole namespace 0, about 100 ms: a few
    // servers per round have to do. One leaked UA_ServerConfig is 1184 bytes.
    await expectNoHeapGrowth(
      () => Server(logLevel: LogLevel.UA_LOGLEVEL_FATAL).delete(),
      warmUp: 2,
      iterations: 4,
      rounds: 5,
      maxGrowth: 256,
      attempts: 3,
    );
  });
}
