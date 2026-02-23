import 'dart:async';
import 'dart:math';

import 'package:test/test.dart';
import 'package:open62541/open62541.dart';
import 'common.dart';

/// Helper: register a custom type (both config-level and address space)
void registerType(Server server, NodeId typeId, DynamicValue schema) {
  server.addCustomType(typeId, schema);
  server.addDataTypeNode(typeId, schema.name!);
}

void main() {
  group('Custom type with string fields', () {
    final port = Random().nextInt(8000) + 30000;
    late Server server;

    setUp(() {
      server = setupServer(port);
    });

    tearDown(() async {
      stopServerLoop();
      await Future.delayed(Duration(milliseconds: 50));
      server.shutdown();
      server.delete();
    });

    test('single string field round-trip', () async {
      final typeId = NodeId.fromString(1, 'SingleStringType');
      final schema = DynamicValue(name: 'SingleString', typeId: typeId);
      schema['label'] = DynamicValue(typeId: NodeId.uastring);
      registerType(server, typeId, schema);

      final value = DynamicValue(name: 'SingleString', typeId: typeId);
      value['label'] = DynamicValue(value: 'hello world', typeId: NodeId.uastring);
      server.addVariableNode(NodeId.fromString(1, 'str_test_1'), value);

      final client = await ClientIsolate.create(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
      unawaited(client.runIterate().catchError((_) {}));
      unawaited(client.connect("opc.tcp://localhost:$port"));
      await client.awaitConnect();

      final result = await client.read(NodeId.fromString(1, 'str_test_1'));
      expect(result.asObject['label']?.value, 'hello world');

      await client.delete();
    });

    test('int32 + string field combination', () async {
      final typeId = NodeId.fromString(1, 'IntAndStringType');
      final schema = DynamicValue(name: 'IntAndString', typeId: typeId);
      schema['count'] = DynamicValue(typeId: NodeId.int32);
      schema['name'] = DynamicValue(typeId: NodeId.uastring);
      registerType(server, typeId, schema);

      final value = DynamicValue(name: 'IntAndString', typeId: typeId);
      value['count'] = DynamicValue(value: 42, typeId: NodeId.int32);
      value['name'] = DynamicValue(value: 'test string', typeId: NodeId.uastring);
      server.addVariableNode(NodeId.fromString(1, 'str_test_2'), value);

      final client = await ClientIsolate.create(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
      unawaited(client.runIterate().catchError((_) {}));
      unawaited(client.connect("opc.tcp://localhost:$port"));
      await client.awaitConnect();

      final result = await client.read(NodeId.fromString(1, 'str_test_2'));
      expect(result.asObject['count']?.value, 42);
      expect(result.asObject['name']?.value, 'test string');

      await client.delete();
    });

    test('multiple string fields', () async {
      final typeId = NodeId.fromString(1, 'MultiStringType');
      final schema = DynamicValue(name: 'MultiString', typeId: typeId);
      schema['first'] = DynamicValue(typeId: NodeId.uastring);
      schema['second'] = DynamicValue(typeId: NodeId.uastring);
      schema['third'] = DynamicValue(typeId: NodeId.uastring);
      registerType(server, typeId, schema);

      final value = DynamicValue(name: 'MultiString', typeId: typeId);
      value['first'] = DynamicValue(value: 'alpha', typeId: NodeId.uastring);
      value['second'] = DynamicValue(value: 'beta', typeId: NodeId.uastring);
      value['third'] = DynamicValue(value: 'gamma', typeId: NodeId.uastring);
      server.addVariableNode(NodeId.fromString(1, 'str_test_3'), value);

      final client = await ClientIsolate.create(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
      unawaited(client.runIterate().catchError((_) {}));
      unawaited(client.connect("opc.tcp://localhost:$port"));
      await client.awaitConnect();

      final result = await client.read(NodeId.fromString(1, 'str_test_3'));
      expect(result.asObject['first']?.value, 'alpha');
      expect(result.asObject['second']?.value, 'beta');
      expect(result.asObject['third']?.value, 'gamma');

      await client.delete();
    });

    test('string + bool + double + int32 mixed fields', () async {
      final typeId = NodeId.fromString(1, 'MixedWithStringType');
      final schema = DynamicValue(name: 'MixedWithString', typeId: typeId);
      schema['label'] = DynamicValue(typeId: NodeId.uastring);
      schema['active'] = DynamicValue(typeId: NodeId.boolean);
      schema['temperature'] = DynamicValue(typeId: NodeId.double);
      schema['count'] = DynamicValue(typeId: NodeId.int32);
      registerType(server, typeId, schema);

      final value = DynamicValue(name: 'MixedWithString', typeId: typeId);
      value['label'] = DynamicValue(value: 'sensor-7', typeId: NodeId.uastring);
      value['active'] = DynamicValue(value: true, typeId: NodeId.boolean);
      value['temperature'] = DynamicValue(value: 23.5, typeId: NodeId.double);
      value['count'] = DynamicValue(value: 99, typeId: NodeId.int32);
      server.addVariableNode(NodeId.fromString(1, 'str_test_4'), value);

      final client = await ClientIsolate.create(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
      unawaited(client.runIterate().catchError((_) {}));
      unawaited(client.connect("opc.tcp://localhost:$port"));
      await client.awaitConnect();

      final result = await client.read(NodeId.fromString(1, 'str_test_4'));
      expect(result.asObject['label']?.value, 'sensor-7');
      expect(result.asObject['active']?.value, true);
      expect(result.asObject['temperature']?.value, closeTo(23.5, 0.01));
      expect(result.asObject['count']?.value, 99);

      await client.delete();
    });

    test('empty string field', () async {
      final typeId = NodeId.fromString(1, 'EmptyStringType');
      final schema = DynamicValue(name: 'EmptyString', typeId: typeId);
      schema['data'] = DynamicValue(typeId: NodeId.uastring);
      registerType(server, typeId, schema);

      final value = DynamicValue(name: 'EmptyString', typeId: typeId);
      value['data'] = DynamicValue(value: '', typeId: NodeId.uastring);
      server.addVariableNode(NodeId.fromString(1, 'str_test_5'), value);

      final client = await ClientIsolate.create(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
      unawaited(client.runIterate().catchError((_) {}));
      unawaited(client.connect("opc.tcp://localhost:$port"));
      await client.awaitConnect();

      final result = await client.read(NodeId.fromString(1, 'str_test_5'));
      expect(result.asObject['data']?.value, anyOf('', null));

      await client.delete();
    });

    test('long string field (1000 chars)', () async {
      final typeId = NodeId.fromString(1, 'LongStringType');
      final schema = DynamicValue(name: 'LongString', typeId: typeId);
      schema['payload'] = DynamicValue(typeId: NodeId.uastring);
      registerType(server, typeId, schema);

      final longString = 'x' * 1000;
      final value = DynamicValue(name: 'LongString', typeId: typeId);
      value['payload'] = DynamicValue(value: longString, typeId: NodeId.uastring);
      server.addVariableNode(NodeId.fromString(1, 'str_test_6'), value);

      final client = await ClientIsolate.create(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
      unawaited(client.runIterate().catchError((_) {}));
      unawaited(client.connect("opc.tcp://localhost:$port"));
      await client.awaitConnect();

      final result = await client.read(NodeId.fromString(1, 'str_test_6'));
      expect(result.asObject['payload']?.value, longString);

      await client.delete();
    });

    test('unicode string in custom type', () async {
      final typeId = NodeId.fromString(1, 'UnicodeStrType');
      final schema = DynamicValue(name: 'UnicodeStr', typeId: typeId);
      schema['text'] = DynamicValue(typeId: NodeId.uastring);
      schema['count'] = DynamicValue(typeId: NodeId.int32);
      registerType(server, typeId, schema);

      final value = DynamicValue(name: 'UnicodeStr', typeId: typeId);
      value['text'] = DynamicValue(value: 'Héllo Wörld 日本語', typeId: NodeId.uastring);
      value['count'] = DynamicValue(value: 42, typeId: NodeId.int32);
      server.addVariableNode(NodeId.fromString(1, 'str_test_7'), value);

      final client = await ClientIsolate.create(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
      unawaited(client.runIterate().catchError((_) {}));
      unawaited(client.connect("opc.tcp://localhost:$port"));
      await client.awaitConnect();

      final result = await client.read(NodeId.fromString(1, 'str_test_7'));
      expect(result.asObject['text']?.value, 'Héllo Wörld 日本語');
      expect(result.asObject['count']?.value, 42);

      await client.delete();
    });
  });

  group('Custom type with string through aggregation (2 servers)', () {
    final portA = Random().nextInt(8000) + 30000;
    final portB = Random().nextInt(8000) + 30000 + 8000;
    late Server serverA;
    late Server serverB;

    setUp(() {
      serverA = setupServer(portA);
      serverB = setupServer(portB);
    });

    tearDown(() async {
      stopServerLoop();
      await Future.delayed(Duration(milliseconds: 50));
      serverA.shutdown();
      serverA.delete();
      serverB.shutdown();
      serverB.delete();
    });

    test('string struct aggregated between two servers', () async {
      final typeId = NodeId.fromString(1, 'AggStringType');
      final schema = DynamicValue(name: 'AggString', typeId: typeId);
      schema['id'] = DynamicValue(typeId: NodeId.int32);
      schema['message'] = DynamicValue(typeId: NodeId.uastring);
      schema['priority'] = DynamicValue(typeId: NodeId.double);
      registerType(serverA, typeId, schema);
      registerType(serverB, typeId, schema);

      final value = DynamicValue(name: 'AggString', typeId: typeId);
      value['id'] = DynamicValue(value: 7, typeId: NodeId.int32);
      value['message'] = DynamicValue(value: 'critical alert', typeId: NodeId.uastring);
      value['priority'] = DynamicValue(value: 9.5, typeId: NodeId.double);
      serverA.addVariableNode(NodeId.fromString(1, 'agg_str_src'), value);
      serverB.addVariableNode(NodeId.fromString(1, 'agg_str_dst'), value);

      final clientA = await ClientIsolate.create(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
      unawaited(clientA.runIterate().catchError((_) {}));
      unawaited(clientA.connect("opc.tcp://localhost:$portA"));
      await clientA.awaitConnect();

      final readA = await clientA.read(NodeId.fromString(1, 'agg_str_src'));
      expect(readA.asObject['id']?.value, 7);
      expect(readA.asObject['message']?.value, 'critical alert');
      expect(readA.asObject['priority']?.value, closeTo(9.5, 0.01));

      final clientB = await ClientIsolate.create(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
      unawaited(clientB.runIterate().catchError((_) {}));
      unawaited(clientB.connect("opc.tcp://localhost:$portB"));
      await clientB.awaitConnect();

      await clientB.write(NodeId.fromString(1, 'agg_str_dst'), readA);

      final readB = await clientB.read(NodeId.fromString(1, 'agg_str_dst'));
      expect(readB.asObject['id']?.value, 7);
      expect(readB.asObject['message']?.value, 'critical alert');
      expect(readB.asObject['priority']?.value, closeTo(9.5, 0.01));

      await clientA.delete();
      await clientB.delete();
    });
  });

  group('Large custom types (memSize stress)', () {
    final port = Random().nextInt(8000) + 30000;
    late Server server;

    setUp(() {
      server = setupServer(port);
    });

    tearDown(() async {
      stopServerLoop();
      await Future.delayed(Duration(milliseconds: 50));
      server.shutdown();
      server.delete();
    });

    test('8 double fields (64 bytes, was broken with memSize=9)', () async {
      final typeId = NodeId.fromString(1, 'EightDoublesType');
      final schema = DynamicValue(name: 'EightDoubles', typeId: typeId);
      for (var i = 0; i < 8; i++) {
        schema['d$i'] = DynamicValue(typeId: NodeId.double);
      }
      registerType(server, typeId, schema);

      final value = DynamicValue(name: 'EightDoubles', typeId: typeId);
      for (var i = 0; i < 8; i++) {
        value['d$i'] = DynamicValue(value: i * 1.1, typeId: NodeId.double);
      }
      server.addVariableNode(NodeId.fromString(1, 'large_1'), value);

      final client = await ClientIsolate.create(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
      unawaited(client.runIterate().catchError((_) {}));
      unawaited(client.connect("opc.tcp://localhost:$port"));
      await client.awaitConnect();

      final result = await client.read(NodeId.fromString(1, 'large_1'));
      for (var i = 0; i < 8; i++) {
        expect(result.asObject['d$i']?.value, closeTo(i * 1.1, 0.01),
            reason: 'Field d$i should be ${i * 1.1}');
      }

      await client.delete();
    });

    test('16 int32 fields (64 bytes)', () async {
      final typeId = NodeId.fromString(1, 'SixteenIntsType');
      final schema = DynamicValue(name: 'SixteenInts', typeId: typeId);
      for (var i = 0; i < 16; i++) {
        schema['i$i'] = DynamicValue(typeId: NodeId.int32);
      }
      registerType(server, typeId, schema);

      final value = DynamicValue(name: 'SixteenInts', typeId: typeId);
      for (var i = 0; i < 16; i++) {
        value['i$i'] = DynamicValue(value: i * 100, typeId: NodeId.int32);
      }
      server.addVariableNode(NodeId.fromString(1, 'large_2'), value);

      final client = await ClientIsolate.create(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
      unawaited(client.runIterate().catchError((_) {}));
      unawaited(client.connect("opc.tcp://localhost:$port"));
      await client.awaitConnect();

      final result = await client.read(NodeId.fromString(1, 'large_2'));
      for (var i = 0; i < 16; i++) {
        expect(result.asObject['i$i']?.value, i * 100,
            reason: 'Field i$i should be ${i * 100}');
      }

      await client.delete();
    });

    test('mixed types: bool, int16, int32, int64, float, double, string', () async {
      final typeId = NodeId.fromString(1, 'AllTypesType');
      final schema = DynamicValue(name: 'AllTypes', typeId: typeId);
      schema['b'] = DynamicValue(typeId: NodeId.boolean);
      schema['i16'] = DynamicValue(typeId: NodeId.int16);
      schema['i32'] = DynamicValue(typeId: NodeId.int32);
      schema['i64'] = DynamicValue(typeId: NodeId.int64);
      schema['f32'] = DynamicValue(typeId: NodeId.float);
      schema['f64'] = DynamicValue(typeId: NodeId.double);
      schema['str'] = DynamicValue(typeId: NodeId.uastring);
      registerType(server, typeId, schema);

      final value = DynamicValue(name: 'AllTypes', typeId: typeId);
      value['b'] = DynamicValue(value: true, typeId: NodeId.boolean);
      value['i16'] = DynamicValue(value: 1234, typeId: NodeId.int16);
      value['i32'] = DynamicValue(value: 56789, typeId: NodeId.int32);
      value['i64'] = DynamicValue(value: 9876543210, typeId: NodeId.int64);
      value['f32'] = DynamicValue(value: 3.14, typeId: NodeId.float);
      value['f64'] = DynamicValue(value: 2.71828, typeId: NodeId.double);
      value['str'] = DynamicValue(value: 'mixed types test', typeId: NodeId.uastring);
      server.addVariableNode(NodeId.fromString(1, 'large_3'), value);

      final client = await ClientIsolate.create(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
      unawaited(client.runIterate().catchError((_) {}));
      unawaited(client.connect("opc.tcp://localhost:$port"));
      await client.awaitConnect();

      final result = await client.read(NodeId.fromString(1, 'large_3'));
      expect(result.asObject['b']?.value, true);
      expect(result.asObject['i16']?.value, 1234);
      expect(result.asObject['i32']?.value, 56789);
      expect(result.asObject['i64']?.value, 9876543210);
      expect(result.asObject['f32']?.value, closeTo(3.14, 0.01));
      expect(result.asObject['f64']?.value, closeTo(2.71828, 0.0001));
      expect(result.asObject['str']?.value, 'mixed types test');

      await client.delete();
    });

    test('4 strings + 4 doubles interleaved', () async {
      final typeId = NodeId.fromString(1, 'InterleavedType');
      final schema = DynamicValue(name: 'Interleaved', typeId: typeId);
      schema['s0'] = DynamicValue(typeId: NodeId.uastring);
      schema['d0'] = DynamicValue(typeId: NodeId.double);
      schema['s1'] = DynamicValue(typeId: NodeId.uastring);
      schema['d1'] = DynamicValue(typeId: NodeId.double);
      schema['s2'] = DynamicValue(typeId: NodeId.uastring);
      schema['d2'] = DynamicValue(typeId: NodeId.double);
      schema['s3'] = DynamicValue(typeId: NodeId.uastring);
      schema['d3'] = DynamicValue(typeId: NodeId.double);
      registerType(server, typeId, schema);

      final value = DynamicValue(name: 'Interleaved', typeId: typeId);
      value['s0'] = DynamicValue(value: 'zero', typeId: NodeId.uastring);
      value['d0'] = DynamicValue(value: 0.0, typeId: NodeId.double);
      value['s1'] = DynamicValue(value: 'one', typeId: NodeId.uastring);
      value['d1'] = DynamicValue(value: 1.1, typeId: NodeId.double);
      value['s2'] = DynamicValue(value: 'two', typeId: NodeId.uastring);
      value['d2'] = DynamicValue(value: 2.2, typeId: NodeId.double);
      value['s3'] = DynamicValue(value: 'three', typeId: NodeId.uastring);
      value['d3'] = DynamicValue(value: 3.3, typeId: NodeId.double);
      server.addVariableNode(NodeId.fromString(1, 'large_4'), value);

      final client = await ClientIsolate.create(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
      unawaited(client.runIterate().catchError((_) {}));
      unawaited(client.connect("opc.tcp://localhost:$port"));
      await client.awaitConnect();

      final result = await client.read(NodeId.fromString(1, 'large_4'));
      expect(result.asObject['s0']?.value, 'zero');
      expect(result.asObject['d0']?.value, closeTo(0.0, 0.01));
      expect(result.asObject['s1']?.value, 'one');
      expect(result.asObject['d1']?.value, closeTo(1.1, 0.01));
      expect(result.asObject['s2']?.value, 'two');
      expect(result.asObject['d2']?.value, closeTo(2.2, 0.01));
      expect(result.asObject['s3']?.value, 'three');
      expect(result.asObject['d3']?.value, closeTo(3.3, 0.01));

      await client.delete();
    });

    test('10 concurrent clients read struct with string', () async {
      final typeId = NodeId.fromString(1, 'ConcurrentStrType');
      final schema = DynamicValue(name: 'ConcurrentStr', typeId: typeId);
      schema['id'] = DynamicValue(typeId: NodeId.int32);
      schema['name'] = DynamicValue(typeId: NodeId.uastring);
      registerType(server, typeId, schema);

      final value = DynamicValue(name: 'ConcurrentStr', typeId: typeId);
      value['id'] = DynamicValue(value: 123, typeId: NodeId.int32);
      value['name'] = DynamicValue(value: 'concurrent-test', typeId: NodeId.uastring);
      server.addVariableNode(NodeId.fromString(1, 'conc_1'), value);

      final clients = <ClientIsolate>[];
      for (var i = 0; i < 10; i++) {
        final c = await ClientIsolate.create(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
        unawaited(c.runIterate().catchError((_) {}));
        unawaited(c.connect("opc.tcp://localhost:$port"));
        await c.awaitConnect();
        clients.add(c);
      }

      final results = await Future.wait(
        clients.map((c) => c.read(NodeId.fromString(1, 'conc_1'))),
      );
      for (var i = 0; i < results.length; i++) {
        expect(results[i].asObject['id']?.value, 123, reason: 'Client $i id');
        expect(results[i].asObject['name']?.value, 'concurrent-test',
            reason: 'Client $i name');
      }

      for (final c in clients) {
        await c.delete();
      }
    });
  });
}
