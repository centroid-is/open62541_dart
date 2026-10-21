// Small networking helpers for the integration suite.

import 'dart:io';

/// Binds an ephemeral port, closes it, and returns the number, for a process
/// that must be told its port up front: the reference servers (they are also
/// restarted on the same port), the PLC emulator and toxiproxy's API.
///
/// This is a probe, not a reservation: the OS may hand the number out again
/// between the close here and the process binding it. Everything that can
/// report its own port does not use it: a Dart [Server] is started with
/// `port: 0` and read back through `Server.port`, and a toxiproxy proxy
/// listens on port 0 and reports the port in its reply.
Future<int> freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final p = s.port;
  await s.close();
  return p;
}
