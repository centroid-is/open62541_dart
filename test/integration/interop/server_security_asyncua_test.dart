// INTEROP: the Dart `Server` refuses node management to a client <-> an
// independent reference CLIENT (asyncua). The default suite proves the same
// with a raw open62541 client (test/server_security_test.dart); this is the
// second implementation, an OPC UA stack that is not open62541 at all.
@Tags(['integration'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import '../harness/paths.dart';

void main() {
  group('Dart Server node management <- asyncua reference client', () {
    /// Starts [server] and pumps it; stopped at the end of the test.
    Future<String> start(Server server) async {
      server.start();
      var running = true;
      unawaited(() async {
        while (running && server.runIterate()) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }());
      addTearDown(() async {
        running = false;
        await Future<void>.delayed(const Duration(milliseconds: 50));
        server.shutdown();
        server.delete();
      });
      await Future<void>.delayed(const Duration(milliseconds: 300));
      return 'opc.tcp://127.0.0.1:${server.port}';
    }

    test('by default AddNodes is answered BadUserAccessDenied', () async {
      final url = await start(Server(port: 0, logLevel: LogLevel.UA_LOGLEVEL_FATAL));
      final steps = await _runReferenceClient(url);
      expect(steps['add_object']?['code'], raw.UA_STATUSCODE_BADUSERACCESSDENIED, reason: '$steps');
      expect(steps.containsKey('done'), isTrue, reason: 'reference client did not finish: $steps');
    });

    test('allowClientNodeManagement: true lets it add and delete a node', () async {
      final url = await start(Server(port: 0, logLevel: LogLevel.UA_LOGLEVEL_FATAL, allowClientNodeManagement: true));
      final steps = await _runReferenceClient(url);
      expect(steps['add_object']?['code'], 0, reason: '$steps');
      expect(steps['delete_node']?['code'], 0, reason: '$steps');
      expect(steps.containsKey('done'), isTrue, reason: 'reference client did not finish: $steps');
    });
  }, skip: asyncuaAvailable() ? false : 'run test/integration/setup_local.sh first');
}

/// Runs the asyncua reference client and returns the JSON objects it printed,
/// keyed by step.
Future<Map<String, Map<String, dynamic>>> _runReferenceClient(String endpoint) async {
  final proc = await Process.start(venvPython(), [serverScript('node_management_asyncua.py'), '--endpoint', endpoint]);
  final out = <String, Map<String, dynamic>>{};
  final stdoutDone = proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
    final trimmed = line.trim();
    if (trimmed.startsWith('{')) {
      final step = jsonDecode(trimmed) as Map<String, dynamic>;
      out[step['step'] as String] = step;
    }
  }).asFuture<void>();
  final errBuf = StringBuffer();
  final stderrDone = proc.stderr.transform(utf8.decoder).listen(errBuf.write).asFuture<void>();
  final code = await proc.exitCode.timeout(
    const Duration(seconds: 45),
    onTimeout: () {
      proc.kill(ProcessSignal.sigkill);
      return -1;
    },
  );
  await stdoutDone;
  await stderrDone;
  if (code != 0) {
    // ignore: avoid_print
    print('reference client exited $code; stderr:\n$errBuf');
  }
  return out;
}
