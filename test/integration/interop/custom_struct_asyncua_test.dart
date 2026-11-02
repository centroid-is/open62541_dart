// INTEROP: a custom structured DataType of the Dart `Server` <-> independent
// reference CLIENT (asyncua), resolved the OPC UA 1.04 way.
//
// asyncua `load_data_type_definitions()` fetches every DataTypeDefinition,
// builds a Python class per structure and keys its decoder on the
// definition's `defaultEncodingId`; `read_value()` returns the class only if
// the ExtensionObject on the wire carries that id (UaExpert resolves a type
// the same way). Before 1.5.9 the Dart server encoded the value under the
// DataType id and asyncua returned an opaque `ExtensionObject`; the Dart
// client never noticed because it resolves the schema from the variable's
// DataType attribute. This is the proof an independent 1.04 client decodes
// the type, writes it, and the Dart side receives the write decoded.
@Tags(['integration'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import '../harness/paths.dart';

final _structType = NodeId.fromString(1, 'ST_Interop');
final _innerType = NodeId.fromString(1, 'ST_Interop_Inner');
final _nodeId = NodeId.fromString(1, 'interop.struct');

DynamicValue _schema() {
  final inner = DynamicValue(name: 'ST_Interop_Inner', typeId: _innerType);
  inner['Flag'] = DynamicValue(value: true, typeId: NodeId.boolean);
  final s = DynamicValue(name: 'ST_Interop', typeId: _structType);
  s['Id'] = DynamicValue(value: 7, typeId: NodeId.int32);
  s['Value'] = DynamicValue(value: 1.5, typeId: NodeId.double);
  s['Label'] = DynamicValue(value: 'initial', typeId: NodeId.uastring);
  s['Inner'] = inner;
  return s;
}

void main() {
  group('Dart Server custom struct <- asyncua reference client (1.04 DataTypeDefinition path)', () {
    late Server server;
    late int serverPort;
    var running = false;
    late DynamicValue backing;
    DynamicValue? received;

    setUp(() async {
      server = Server(port: 0, logLevel: LogLevel.UA_LOGLEVEL_FATAL);
      server.start();
      serverPort = server.port;
      server.addCustomType(_structType, _schema());
      server.addDataTypeNode(_structType, 'ST_Interop');
      backing = _schema();
      received = null;
      server.addDataSourceVariableNode(
        _nodeId,
        browseName: 'InteropStruct',
        typeId: _structType,
        onRead: () => backing,
        onWrite: (value) async {
          received = value;
          backing = value;
        },
      );
      running = true;
      unawaited(() async {
        while (running && server.runIterate()) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }());
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });

    tearDown(() async {
      running = false;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      server.shutdown();
      server.delete();
    });

    test(
      'asyncua decodes the struct from the DataTypeDefinition, writes it, and onWrite receives it decoded',
      () async {
        final result = await _runReferenceClient('opc.tcp://127.0.0.1:$serverPort');
        final byStep = {for (final m in result) m['step'] as String: m};
        expect(byStep['error'], isNull, reason: 'reference client errored: ${byStep['error']}');
        expect(byStep.containsKey('done'), isTrue, reason: 'reference client did not finish: $result');

        // 1. The address space: the DataType attribute, a definition whose
        //    defaultEncodingId is the one HasEncoding target (`Default Binary`),
        //    and that very id on the wire.
        final space = byStep['address_space']!;
        expect(space['data_type'], 'ns=1;s=ST_Interop');
        expect(space['fields'], ['Id', 'Value', 'Label', 'Inner']);
        expect(space['has_encoding_targets'], ['ns=1;s=ST_Interop_Encoding_DefaultBinary']);
        expect(space['encoding_browse_names'], ['0:Default Binary']);
        expect(space['default_encoding_id'], 'ns=1;s=ST_Interop_Encoding_DefaultBinary');
        expect(space['wire_type_id'], space['default_encoding_id'], reason: 'the wire id is the advertised one');

        // 2. The 1.04 path decodes it into the generated class, not ExtensionObject.
        final read = byStep['read']!;
        expect(read['python_type'], 'ST_Interop');
        expect(read['fields'], {
          'Id': 7,
          'Value': 1.5,
          'Label': 'initial',
          'Inner': {'Flag': true},
        });

        // 3. The external write reached the data source decoded.
        expect(received, isNotNull, reason: 'onWrite was not called');
        expect(received!['Id'].asInt, 42);
        expect(received!['Label'].asString, 'from-asyncua');
        expect(received!['Value'].asDouble, 1.5);
        expect(received!['Inner']['Flag'].asBool, isFalse);
        expect(received!.extObjEncodingId, NodeId.fromString(1, 'ST_Interop_Encoding_DefaultBinary'));

        // 4. And asyncua read its own write back, decoded.
        final back = byStep['read_back']!;
        expect(back['python_type'], 'ST_Interop');
        expect(back['fields'], {
          'Id': 42,
          'Value': 1.5,
          'Label': 'from-asyncua',
          'Inner': {'Flag': false},
        });
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  }, skip: asyncuaAvailable() ? false : 'run test/integration/setup_local.sh first');
}

/// Runs the asyncua reference client and returns the JSON objects it printed
/// (one per step).
Future<List<Map<String, dynamic>>> _runReferenceClient(String endpoint) async {
  final proc = await Process.start(venvPython(), [
    serverScript('custom_struct_asyncua.py'),
    '--endpoint',
    endpoint,
    '--node',
    _nodeId.toString(),
    '--type',
    _structType.toString(),
  ]);
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
    // ignore: avoid_print
    print('reference client exited $code; stderr:\n$errBuf');
  }
  return out;
}
