// INTEROP: Dart `Server` <-> independent reference CLIENT (asyncua).
//
// Proves our server interoperates *outward*: an independent OPC UA stack
// (asyncua, driven as a child process) connects to a Dart-hosted server,
// browses, reads the seeded values, writes new ones, and reads them back.
// The Dart test then confirms the server's own view reflects the external
// writes. This is the mirror image of the client-side matrix and is unique
// coverage the client tests can't provide.
@Tags(['integration'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import '../harness/net.dart';
import '../harness/paths.dart';

// The ns=1 string-id nodes seeded by `addBasicVariables` (mirrors test/common.dart).
final _boolNodeId = NodeId.fromString(1, 'the.bool');
final _intNodeId = NodeId.fromString(1, 'the.int');
final _doubleNodeId = NodeId.fromString(1, 'the.double');
final _stringNodeId = NodeId.fromString(1, 'the.string');

void _addBasicVariables(Server server) {
  server.addVariableNode(
    _boolNodeId,
    DynamicValue(value: true, typeId: NodeId.boolean, name: 'the.bool'),
    accessLevel: AccessLevelMask(read: true, write: true),
  );
  server.addVariableNode(
    _intNodeId,
    DynamicValue(value: 1, typeId: NodeId.int32, name: 'the.int'),
    accessLevel: AccessLevelMask(read: true, write: true),
  );
  server.addVariableNode(
    _doubleNodeId,
    DynamicValue(value: 3.14, typeId: NodeId.double, name: 'the.double'),
    accessLevel: AccessLevelMask(read: true, write: true),
  );
  server.addVariableNode(
    _stringNodeId,
    DynamicValue(value: 'Hello World!', typeId: NodeId.uastring, name: 'the.string'),
    accessLevel: AccessLevelMask(read: true, write: true),
  );
}

void main() {
  group('Dart Server <- asyncua reference client', () {
    late Server server;
    late int serverPort;
    var running = false;

    setUp(() async {
      serverPort = await freePort();
      server = Server(port: serverPort, logLevel: LogLevel.UA_LOGLEVEL_FATAL);
      server.start();
      _addBasicVariables(server);
      running = true;
      unawaited(() async {
        while (running && server.runIterate()) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }());
      // Give the listen socket a moment to come up before the external client.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      _server = server;
    });

    tearDown(() async {
      running = false;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      server.shutdown();
      server.delete();
    });

    test('external client reads seeded values, writes, and reads back; '
        'server view reflects the external writes', () async {
      final endpoint = 'opc.tcp://127.0.0.1:$serverPort';
      final result = await _runReferenceClient(endpoint);

      // The reference client emitted one JSON object per step.
      final byStep = {for (final m in result) m['step'] as String: m};

      expect(byStep['error'], isNull, reason: 'reference client errored: ${byStep['error']}');
      expect(byStep.containsKey('done'), isTrue, reason: 'reference client did not finish: $result');

      // 1. External client saw the values the Dart server seeded.
      final initial = byStep['read_initial']!;
      expect(initial['double'], closeTo(3.14, 1e-9));
      expect(initial['bool'], isTrue);
      expect(initial['int'], 1);
      expect(initial['string'], 'Hello World!');

      // 2. Browsing the Dart server's Objects folder found the node by BrowseName.
      expect(
        byStep['browse']!['found_the_double'],
        isNotNull,
        reason: 'external client could not browse-resolve the.double',
      );

      // 3. External writes were accepted and read back by the same client.
      final readBack = byStep['read_back']!;
      expect(readBack['double'], closeTo(42.5, 1e-9));
      expect(readBack['bool'], isFalse);
      expect(readBack['int'], 1234);
      expect(readBack['string'], 'from-asyncua');

      // 4. The Dart server's *own* view now reflects the external writes.
      expect(_server.read(_doubleNodeId).asDouble, closeTo(42.5, 1e-9));
      expect(_server.read(_boolNodeId).asBool, isFalse);
      expect(_server.read(_intNodeId).asInt, 1234);
      expect(_server.read(_stringNodeId).asString, 'from-asyncua');
    }, timeout: const Timeout(Duration(seconds: 60)));
  }, skip: asyncuaAvailable() ? false : 'run test/integration/setup_local.sh first');
}

late Server _server;

/// Runs the asyncua reference client against [endpoint] and returns the list of
/// JSON objects it printed (one per step).
Future<List<Map<String, dynamic>>> _runReferenceClient(String endpoint) async {
  final proc = await Process.start(venvPython(), [serverScript('reference_client_asyncua.py'), '--endpoint', endpoint]);

  final out = <Map<String, dynamic>>[];
  final stdoutDone = proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
    final trimmed = line.trim();
    if (trimmed.startsWith('{')) {
      out.add(jsonDecode(trimmed) as Map<String, dynamic>);
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
    // Surface stderr for diagnosis but still return what we parsed.
    // ignore: avoid_print
    print('reference client exited $code; stderr:\n$errBuf');
  }
  return out;
}
