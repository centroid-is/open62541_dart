// Regression test for a whole-process SIGSEGV on a spec-legal server answer:
// status GOOD with an EMPTY variant ("the attribute exists and carries no
// value", OPC UA Part 4).
//
// Symptom
//   An empty variant has `type == NULL` and `data == NULL`. Three client
//   paths dereferenced those pointers natively without checking:
//     * Client.readAttribute — every case of its attribute switch
//       (`value!.data.cast<...>().ref`, and the DataTypeDefinition case's
//       `value!.type.ref.typeId`),
//     * the monitored-items notification callback — same switch shape, for a
//       GOOD sample carrying no value (a Bad sample without a value was
//       already guarded), and
//     * _variantToValueAutoSchema — `data.type.ref.typeId` on its first line.
//   The result is a native SIGSEGV (si_addr = a small struct-field offset),
//   killing the whole process — NOT a catchable Dart exception.
//
// Who answers like this in the wild
//   python-asyncua answers Good+empty for the DataTypeDefinition attribute of
//   all 497 base DataType nodes of its standard address space. TwinCAT
//   answers BadAttributeIdInvalid instead — which readAttribute already
//   tolerates — so the crash stays latent against TwinCAT and kills the
//   client against asyncua (and any other server, simulator or gateway that
//   picks the Good+empty shape).
//
// Fixture
//   The Dart Server wrapper cannot produce the shape (addVariableNode
//   requires a value; valueToVariant throws on a null DynamicValue), so the
//   server here is built from the raw bindings: a variable node added with
//   UA_VariableAttributes_default keeps the default EMPTY value variant, and
//   open62541 then answers Value reads and monitor notifications for it with
//   status Good and no payload.
//
// Red/green
//   At the parent commit of the fix, `dart test test/good_status_empty_variant_test.dart`
//   dies with SIGSEGV before any expectation runs (the harness reports the
//   suite as crashed). With the fix, the empty answer is treated exactly like
//   the already-tolerated BadAttributeIdInvalid path: the attribute is absent,
//   the VM stays alive.

import 'dart:async';
import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/common.dart' show valueToVariant;
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'package:open62541/src/ua_allocation.dart' show ua_calloc, ua_malloc;
import 'common.dart' show clientTypes, freeTcpPort, setupClientOfType;

final emptyNodeId = NodeId.fromString(1, "the.empty");

void main() {
  ffi.Pointer<raw.UA_Server> server = ffi.nullptr;
  var serverStarted = false;
  Timer? serverTimer;
  ClientApi? client;

  Future<int> startRawServer() async {
    final port = await freeTcpPort();

    final config = ua_calloc<raw.UA_ServerConfig>();
    config.ref.logging = raw.UA_Log_Stdout_new(raw.UA_LogLevel.UA_LOGLEVEL_ERROR);
    final cfgStatus = raw.UA_ServerConfig_setMinimal(config, port, ffi.nullptr);
    if (cfgStatus != UA_STATUSCODE_GOOD) {
      ua_calloc.free(config);
      fail('server config must build, got ${statusCodeToString(cfgStatus)}');
    }
    // UA_Server_newWithConfig moves the config's content into the server and
    // zeroes the struct it was handed; the calloc'd shell stays ours to free.
    server = raw.UA_Server_newWithConfig(config);
    ua_calloc.free(config);
    expect(server, isNot(ffi.nullptr), reason: 'server must be created');

    // The node under test: UA_VariableAttributes_default carries an EMPTY
    // value variant, and no value is ever written — so the server answers
    // Value reads with status Good and an empty variant.
    final attr = raw.UA_VariableAttributes_new();
    attr.ref = raw.UA_VariableAttributes_default;
    final namePtr = "the.empty".toNativeUtf8(allocator: ua_malloc);
    final nodeIdRaw = emptyNodeId.toRaw();
    final addStatus = raw.UA_Server_addVariableNode(
      server,
      nodeIdRaw,
      NodeId.fromNumeric(0, raw.UA_NS0ID_OBJECTSFOLDER).toRaw(),
      NodeId.fromNumeric(0, raw.UA_NS0ID_ORGANIZES).toRaw(),
      raw.UA_QUALIFIEDNAME(1, namePtr.cast()),
      NodeId.fromNumeric(0, raw.UA_NS0ID_BASEDATAVARIABLETYPE).toRaw(),
      attr.ref,
      ffi.nullptr,
      ffi.nullptr,
    );
    // open62541 deep-copied the NodeId and the browse name; free our copies.
    ua_malloc.free(nodeIdRaw.identifier.string.data);
    ua_malloc.free(namePtr);
    raw.UA_VariableAttributes_delete(attr);
    expect(addStatus, equals(UA_STATUSCODE_GOOD), reason: 'valueless variable node must be added');

    final startStatus = raw.UA_Server_run_startup(server);
    expect(startStatus, equals(UA_STATUSCODE_GOOD), reason: 'server must start');
    serverStarted = true;
    serverTimer = Timer.periodic(Duration(milliseconds: 10), (_) {
      raw.UA_Server_run_iterate(server, false);
    });
    return port;
  }

  // Runs whether the test passed or not, so a failed expectation cannot leak
  // the client, the timer or the native server into the next test. The client
  // goes first: its delete() tears down any monitored-item stream still
  // listening and needs the server to answer.
  tearDown(() async {
    await client?.delete();
    client = null;
    serverTimer?.cancel();
    serverTimer = null;
    if (server != ffi.nullptr) {
      if (serverStarted) raw.UA_Server_run_shutdown(server);
      raw.UA_Server_delete(server);
      server = ffi.nullptr;
      serverStarted = false;
    }
  });

  /// Writes [value] to the node under test from the server side; null writes
  /// an EMPTY variant, which no client-side [DynamicValue] can express.
  void writeFromServer(int? value) {
    final variant = value == null
        ? raw.UA_Variant_new()
        : valueToVariant(DynamicValue(value: value, typeId: NodeId.int32));
    final nodeIdRaw = emptyNodeId.toRaw();
    final status = raw.UA_Server_writeValue(server, nodeIdRaw, variant.ref);
    ua_malloc.free(nodeIdRaw.identifier.string.data);
    raw.UA_Variant_delete(variant);
    expect(status, equals(UA_STATUSCODE_GOOD), reason: 'server-side write of $value must succeed');
  }

  for (final clientType in clientTypes) {
    // Regression tests for PR #118 (Good status with an empty Value) and its
    // review: the first version only looked at the FIRST notification.
    group('Good empty Value [$clientType]', () {
      test('readAttribute of a Good empty Value answers "attribute absent", not SIGSEGV', () async {
        final port = await startRawServer();
        client = await setupClientOfType(clientType, 'opc.tcp://127.0.0.1:$port');

        // Pre-fix this read killed the process; reaching the expectation at
        // all is the proof that it no longer does.
        final result = await client!.readAttribute({
          emptyNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE],
        });

        // The empty answer is treated like the tolerated BadAttributeIdInvalid
        // path: the attribute is absent from the result.
        expect(result[emptyNodeId]?.isNull ?? true, isTrue, reason: 'an empty Value must decode to no value');
      }, timeout: Timeout(Duration(seconds: 30)));

      test('monitor emits null with status Good when the Value goes empty, not the previous value', () async {
        final port = await startRawServer();
        client = await setupClientOfType(clientType, 'opc.tcp://127.0.0.1:$port');

        final subscriptionId = await client!.subscriptionCreate(
          requestedPublishingInterval: Duration(milliseconds: 50),
        );

        // Snapshots taken at emission time: the direct client re-emits one
        // mutable DynamicValue, so keeping the objects would compare the last
        // sample with itself.
        final samples = <(dynamic, int?)>[];
        final errors = <Object>[];
        final subscription = client!
            .monitor(emptyNodeId, subscriptionId, samplingInterval: Duration(milliseconds: 50))
            .listen((value) => samples.add((value.value, value.statusCode)), onError: errors.add);
        addTearDown(subscription.cancel);

        Future<void> untilSamples(int count) async {
          final start = DateTime.now();
          while (samples.length < count && errors.isEmpty && DateTime.now().difference(start) < Duration(seconds: 5)) {
            await Future.delayed(Duration(milliseconds: 20));
          }
        }

        // The initial notification samples the valueless variable: status
        // Good, no payload. Before PR #118 that notification killed the process.
        await untilSamples(1);
        writeFromServer(42);
        await untilSamples(2);
        writeFromServer(null);
        await untilSamples(3);
        writeFromServer(7);
        await untilSamples(4);

        expect(errors, isEmpty, reason: 'a Good empty sample is not an error');
        expect(
          samples,
          [(null, UA_STATUSCODE_GOOD), (42, UA_STATUSCODE_GOOD), (null, UA_STATUSCODE_GOOD), (7, UA_STATUSCODE_GOOD)],
          reason:
              'empty -> 42 -> empty -> 7 on the server must arrive as exactly that; a Good '
              'empty sample that keeps the previous value reports 42 as current while read() answers null',
        );
      }, timeout: Timeout(Duration(seconds: 30)));
    });
  }
}
