// Helpers to bring up a driven, connected Dart client for integration tests.
//
// The direct `Client` needs its event loop pumped by a `runIterate` loop; the
// `ClientIsolate` pumps itself. Both implement `ClientApi`, so tests written
// against `ClientApi` run unchanged on either. `clientTypes` lets a test group
// parameterize over both.

import 'dart:async';

import 'package:open62541/open62541.dart';

enum ClientKind { direct, isolate }

const clientTypes = ClientKind.values;

/// A connected client plus the machinery to tear it down cleanly.
class DrivenClient {
  DrivenClient(this.client, this._dispose, this.kind);

  final ClientApi client;
  final ClientKind kind;
  final Future<void> Function() _dispose;

  Future<void> dispose() => _dispose();
}

/// Connects a client of [kind] to [url]. The returned client is session-active.
///
/// [iterate] is the direct-client pump period; [connectTimeout] bounds the
/// initial connect (important when a toxic is slowing the link).
Future<DrivenClient> connectClient(
  String url, {
  ClientKind kind = ClientKind.direct,
  LogLevel logLevel = LogLevel.UA_LOGLEVEL_FATAL,
  Duration iterate = const Duration(milliseconds: 10),
  Duration connectTimeout = const Duration(seconds: 20),
}) async {
  switch (kind) {
    case ClientKind.direct:
      final client = Client(logLevel: logLevel);
      var running = true;
      // Fire-and-forget pump loop (mirrors test/common.dart).
      unawaited(() async {
        while (running && client.runIterate(iterate)) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }());
      await client.connect(url).timeout(connectTimeout);
      return DrivenClient(client, () async {
        running = false;
        await client.delete();
      }, kind);

    case ClientKind.isolate:
      final client = await ClientIsolate.create(logLevel: logLevel, iterateInterval: iterate);
      // The isolate iterate loop is errored with ClientIsolateClosedException on
      // delete(); swallow it so it doesn't escape as an uncaught zone error and
      // fail test teardown (mirrors test/async_integration_test.dart).
      unawaited(client.runIterate(duration: iterate).catchError((_) {}));
      await client.connect(url).timeout(connectTimeout);
      return DrivenClient(client, () async {
        await client.delete();
      }, kind);
  }
}
