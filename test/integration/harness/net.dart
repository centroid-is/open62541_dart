// Small networking helpers for the integration suite.

import 'dart:io';

/// Binds an ephemeral port, closes it, and returns the number. There is an
/// inherent (small) TOCTOU race, but it is good enough for local tests and far
/// less collision-prone than fixed ports.
Future<int> freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final p = s.port;
  await s.close();
  return p;
}
