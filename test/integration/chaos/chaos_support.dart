// Shared helpers for the NETWORK CHAOS integration category.
//
// This file has no `_test.dart` suffix, so `dart test` will not execute it as a
// suite; it is imported by the chaos_*_test.dart files.

import 'dart:async';

import 'package:open62541/open62541.dart';

/// A Dart OPC UA server that hosts a single large 1-D Double array node and
/// drives itself with an internal `runIterate` loop.
///
/// It gives the chaos tests a *controllable* large payload upstream so the
/// bandwidth and slicer toxics can be validated for byte-exact data integrity
/// (the fish-farm reference model only exposes scalar sensor values).
class LargeArrayServer {
  LargeArrayServer._(this.server, this.port, this.nodeId, this.data, this._stop);

  final Server server;
  final int port;
  final NodeId nodeId;
  final List<double> data;
  final void Function() _stop;

  /// Number of payload bytes in the array value (8 bytes / Double).
  int get byteLength => data.length * 8;

  static Future<LargeArrayServer> start({required int port, int length = 8000}) async {
    final server = Server(port: port, logLevel: LogLevel.UA_LOGLEVEL_FATAL);
    server.start();
    var running = true;
    unawaited(() async {
      while (running && server.runIterate()) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }());
    final nodeId = NodeId.fromString(1, 'chaos.big.array');
    final data = List<double>.generate(length, (i) => i * 1.5 + 0.25);
    server.addVariableNode(nodeId, DynamicValue.fromList(data, typeId: NodeId.double, name: 'chaos.big.array'));
    return LargeArrayServer._(server, port, nodeId, data, () => running = false);
  }

  Future<void> stop() async {
    _stop();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    server.shutdown();
    server.delete();
  }
}

/// Polls [check] until it is true or [timeout] elapses; returns the final value.
///
/// A robust alternative to fixed sleeps on a load-sensitive, shared machine.
Future<bool> waitUntil(
  bool Function() check, {
  Duration timeout = const Duration(seconds: 20),
  Duration step = const Duration(milliseconds: 100),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (check()) return true;
    await Future<void>.delayed(step);
  }
  return check();
}

/// Verifies a read-back Double array against [expected]. Returns `null` on a
/// byte-exact match, otherwise a human-readable description of the first defect.
String? arrayMismatch(DynamicValue v, List<double> expected) {
  if (!v.isArray) return 'value is not an array (got ${v.type})';
  final arr = v.asArray;
  if (arr.length != expected.length) {
    return 'length ${arr.length} != expected ${expected.length}';
  }
  for (var i = 0; i < expected.length; i++) {
    final got = v[i].asDouble;
    if ((got - expected[i]).abs() > 1e-9) {
      return 'element $i: got $got, expected ${expected[i]}';
    }
  }
  return null;
}

/// Attempts a single read of [nodeId] on [client], returning whether it
/// succeeded within [timeout]. Never throws — used to probe post-fault recovery.
Future<bool> tryRead(ClientApi client, NodeId nodeId, {Duration timeout = const Duration(seconds: 5)}) async {
  try {
    await client.read(nodeId).timeout(timeout);
    return true;
  } catch (_) {
    return false;
  }
}

/// Polls [client] with [tryRead] until a read succeeds or [timeout] elapses.
/// Used to assert the channel has recovered after a toxic is removed.
Future<bool> waitForRead(
  ClientApi client,
  NodeId nodeId, {
  Duration timeout = const Duration(seconds: 30),
  Duration readTimeout = const Duration(seconds: 3),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await tryRead(client, nodeId, timeout: readTimeout)) return true;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  return false;
}
