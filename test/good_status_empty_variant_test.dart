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
// Fixtures
//   The Value attribute: the Dart Server wrapper cannot produce the shape
//   (addVariableNode requires a value; valueToVariant throws on a null
//   DynamicValue), so that server is built from the raw bindings. A variable
//   node added with UA_VariableAttributes_default keeps the default EMPTY
//   value variant, and open62541 then answers Value reads and monitor
//   notifications for it with status Good and no payload.
//   Every other attribute: no open62541 server answers DisplayName,
//   Description, DataType or DataTypeDefinition with an empty variant, so
//   those answers are rewritten on the wire by DataValueRewritingProxy, in
//   front of an ordinary in-process Server.
//   Method outputs: a method that declares an output argument and returns
//   none leaves that output variant empty.
//
// Red/green
//   Each of the three guards has a test here that dies with SIGSEGV when that
//   guard alone is removed (the harness reports the suite as crashed, there is
//   no expectation failure to read): the readAttribute guard by the non-Value
//   attribute reads, the monitor guard by the non-Value attribute
//   notifications, the _variantToValueAutoSchema guard by the Value read and
//   by Client.call.

import 'dart:async';
import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/common.dart' show valueToVariant;
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'package:open62541/src/ua_allocation.dart' show ua_calloc, ua_malloc;
import 'common.dart' show clientTypes, freeTcpPort, setupClientOfType;
import 'data_value_rewriting_proxy.dart';

final emptyNodeId = NodeId.fromString(1, "the.empty");
final intNodeId = NodeId.fromString(1, "the.int");
final structTypeId = NodeId.fromString(1, "the.structType");
final methodNodeId = NodeId.fromString(1, "the.method");

/// The two wire shapes of "Good, and no value": `hasValue` clear, and
/// `hasValue` set around a null variant. Both decode to `type == NULL`.
const emptyShapes = [('hasValue clear', goodWithoutValue), ('an empty variant', goodWithEmptyVariant)];

/// Polls until [condition] holds, giving up after five seconds.
Future<void> until(bool Function() condition) async {
  final start = DateTime.now();
  while (!condition() && DateTime.now().difference(start) < Duration(seconds: 5)) {
    await Future.delayed(Duration(milliseconds: 20));
  }
}

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
      test('readAttribute returns the node with a null value for a Good empty Value', () async {
        final port = await startRawServer();
        client = await setupClientOfType(clientType, 'opc.tcp://127.0.0.1:$port');

        // Before PR #118 this read killed the process; reaching the
        // expectations at all is the proof that it no longer does.
        final result = await client!.readAttribute({
          emptyNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE],
        });

        // One contract, the same the monitor path and read() have: the node
        // was read, so it is in the result, and its value is null.
        expect(result.keys, [
          emptyNodeId,
        ], reason: 'a Good answer is an answer: the node must be in the result, or results[nodeId]! throws');
        expect(result[emptyNodeId]!.isNull, isTrue, reason: 'an empty Value decodes to a null value');
        expect((await client!.read(emptyNodeId)).isNull, isTrue, reason: 'read() must agree with readAttribute()');
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

        Future<void> untilSamples(int count) => until(() => samples.length >= count || errors.isNotEmpty);

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

  for (final clientType in clientTypes) {
    // Regression tests for the review of PR #118: the tests it shipped stayed
    // green with any one of the three empty-variant guards removed.
    group('Good empty answers [$clientType]', () {
      Server? server;
      Timer? timer;
      DataValueRewritingProxy? proxy;
      ClientApi? client;

      // One server and one client for the whole group: deleting a direct
      // client while its server shares the isolate costs seconds per test.
      setUpAll(() async {
        final port = await freeTcpPort();
        server = Server(port: port, logLevel: LogLevel.UA_LOGLEVEL_FATAL);
        server!.start();
        server!.addVariableNode(intNodeId, DynamicValue(value: 42, typeId: NodeId.int32, name: "the.int"));
        // A DataType node with a real DataTypeDefinition, so that attribute
        // can be monitored at all (on a variable node the create is refused).
        final struct = DynamicValue(name: "the.struct", typeId: structTypeId);
        struct["a"] = DynamicValue(value: 1, typeId: NodeId.int32);
        server!.addCustomType(structTypeId, struct);
        server!.addDataTypeNode(structTypeId, "the.structType");
        // Declares one output and returns none: the output stays an empty variant.
        server!.addMethodNode(
          methodNodeId,
          callback: (inputs, session) async => [],
          outputArguments: [Argument(name: 'out', dataType: NodeId.int32)],
        );
        timer = Timer.periodic(Duration(milliseconds: 10), (_) => server!.runIterate());

        proxy = await DataValueRewritingProxy.start(port);
        client = await setupClientOfType(clientType, 'opc.tcp://127.0.0.1:${proxy!.port}');
      });

      tearDownAll(() async {
        await client?.delete();
        await proxy?.close();
        timer?.cancel();
        server?.shutdown();
        server?.delete();
      });

      tearDown(() {
        proxy?.rewriteRead = null;
        proxy?.rewriteNotification = null;
      });

      /// What a DynamicValue carries, as plain values: the direct client
      /// re-emits one mutable object.
      (dynamic, NodeId?, String?, String?) snapshot(DynamicValue? value) =>
          (value?.value, value?.typeId, value?.displayName?.value, value?.description?.value);

      const metadataAttributes = [
        (AttributeId.UA_ATTRIBUTEID_DESCRIPTION, 'Description'),
        (AttributeId.UA_ATTRIBUTEID_DISPLAYNAME, 'DisplayName'),
        (AttributeId.UA_ATTRIBUTEID_DATATYPE, 'DataType'),
        (AttributeId.UA_ATTRIBUTEID_DATATYPEDEFINITION, 'DataTypeDefinition'),
      ];

      for (final (shape, rewrite) in emptyShapes) {
        for (final (attribute, name) in metadataAttributes) {
          final nodeId = attribute == AttributeId.UA_ATTRIBUTEID_DATATYPEDEFINITION ? structTypeId : intNodeId;

          test('readAttribute treats a $name answered Good with $shape as absent', () async {
            final rewritesBefore = proxy!.readRewrites;
            proxy!.rewriteRead = rewrite;
            final result = await client!.readAttribute({
              nodeId: [attribute],
            });
            proxy!.rewriteRead = null;

            expect(proxy!.readRewrites, greaterThan(rewritesBefore), reason: 'the answer must have been rewritten');
            expect(
              result,
              isEmpty,
              reason: 'like the tolerated BadAttributeIdInvalid: the $name is absent, so nothing is added for the node',
            );
          });

          test('monitoredItems delivers a $name notification that is Good with $shape as absent', () async {
            final rewritesBefore = proxy!.notificationRewrites;
            proxy!.rewriteNotification = rewrite;
            final subscriptionId = await client!.subscriptionCreate(
              requestedPublishingInterval: Duration(milliseconds: 50),
            );
            final events = <(dynamic, NodeId?, String?, String?)>[];
            final errors = <Object>[];
            final subscription = client!
                .monitoredItems(
                  {
                    nodeId: [attribute],
                  },
                  subscriptionId,
                  samplingInterval: Duration(milliseconds: 50),
                )
                .listen((event) => events.add(snapshot(event[nodeId])), onError: errors.add);
            addTearDown(subscription.cancel);
            await until(() => events.isNotEmpty || errors.isNotEmpty);

            expect(
              proxy!.notificationRewrites,
              greaterThan(rewritesBefore),
              reason: 'the notification must have been rewritten',
            );
            expect(errors, isEmpty, reason: 'a Good empty $name is not an error');
            expect(events, [
              (null, null, null, null),
            ], reason: 'the notification is delivered, and the $name it did not carry stays unset');
          });
        }

        test('readAttribute returns a null value for a Value answered Good with $shape', () async {
          final rewritesBefore = proxy!.readRewrites;
          proxy!.rewriteRead = rewrite;
          final result = await client!.readAttribute({
            intNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE],
          });
          proxy!.rewriteRead = null;

          expect(proxy!.readRewrites, greaterThan(rewritesBefore), reason: 'the answer must have been rewritten');
          expect(result.keys, [intNodeId], reason: 'the node was read, so it is in the result');
          expect(result[intNodeId]!.isNull, isTrue, reason: 'an empty Value decodes to a null value');
        });

        test('monitoredItems delivers a Value notification that is Good with $shape as null', () async {
          final rewritesBefore = proxy!.notificationRewrites;
          proxy!.rewriteNotification = rewrite;
          final subscriptionId = await client!.subscriptionCreate(
            requestedPublishingInterval: Duration(milliseconds: 50),
          );
          final events = <(dynamic, int?)>[];
          final errors = <Object>[];
          final subscription = client!
              .monitoredItems(
                {
                  intNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE],
                },
                subscriptionId,
                samplingInterval: Duration(milliseconds: 50),
              )
              .listen(
                (event) => events.add((event[intNodeId]?.value, event[intNodeId]?.statusCode)),
                onError: errors.add,
              );
          addTearDown(subscription.cancel);
          await until(() => events.isNotEmpty || errors.isNotEmpty);

          expect(
            proxy!.notificationRewrites,
            greaterThan(rewritesBefore),
            reason: 'the notification must have been rewritten',
          );
          expect(errors, isEmpty, reason: 'a Good empty sample is not an error');
          expect(events, [(null, UA_STATUSCODE_GOOD)], reason: 'the server holds 42; the client was told "empty"');
        });
      }

      test('call returns a null DynamicValue for an output argument the server left empty', () async {
        final outputs = await client!.call(NodeId.objectsFolder, methodNodeId, []);

        expect(outputs, hasLength(1), reason: 'the method declares one output argument');
        expect(outputs.single.isNull, isTrue, reason: 'an empty output variant decodes to a null DynamicValue');
      });
    });
  }
}
