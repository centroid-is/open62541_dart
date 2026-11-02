// The client's DataType definition cache is bounded: a server that serves
// many distinct custom types (it chooses the ids) does not grow it past
// schemaCacheSize, and every value still decodes, including types read
// again after the cache was emptied.

import 'dart:async';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart';

const _types = 12;
// Odd: a readValue adds a definition and then its encoding-id alias, so with
// an odd cap some alias lands on a full cache and empties it while that
// read still needs the definition it just fetched.
const _cacheSize = 5;

NodeId _type(int i) => NodeId.fromString(1, 'ST_Cache_$i');
NodeId _variable(int i) => NodeId.fromString(1, 'cache.$i');

DynamicValue _value(int i) {
  final s = DynamicValue(name: 'ST_Cache_$i', typeId: _type(i));
  s['Id'] = DynamicValue(value: i, typeId: NodeId.int32);
  s['Label'] = DynamicValue(value: 'type $i', typeId: NodeId.uastring);
  return s;
}

Future<ClientApi> _connect(String clientType, int port) async {
  final url = 'opc.tcp://127.0.0.1:$port';
  switch (clientType) {
    case 'isolate':
      final client = await ClientIsolate.create(logLevel: LogLevel.UA_LOGLEVEL_FATAL, schemaCacheSize: _cacheSize);
      unawaited(client.runIterate().catchError((_) {}));
      await client.connect(url);
      return client;
    case 'direct':
      final client = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL, schemaCacheSize: _cacheSize);
      () async {
        while (client.runIterate(const Duration(milliseconds: 10))) {
          await Future.delayed(const Duration(milliseconds: 5));
        }
      }();
      await client.connect(url);
      return client;
    default:
      throw ArgumentError(clientType);
  }
}

void main() {
  for (final clientType in clientTypes) {
    group('$clientType client: schema cache bound', () {
      late Server server;
      late ClientApi client;

      setUp(() async {
        server = setupServer();
        for (var i = 0; i < _types; i++) {
          server.addCustomType(_type(i), _value(i));
          server.addDataTypeNode(_type(i), 'ST_Cache_$i');
          server.addVariableNode(_variable(i), _value(i), typeId: _type(i));
        }
        client = await _connect(clientType, server.port);
      });

      tearDown(() async {
        await client.delete();
        server.shutdown();
        server.delete();
      });

      void expectBounded() {
        if (client case Client c) {
          expect(c.defs.length, lessThanOrEqualTo(_cacheSize));
        }
      }

      test('reads of more distinct types than the cap keep the cache within it', () async {
        // Twice round: the second pass reads types whose definitions were
        // dropped, which must be fetched again.
        for (var pass = 0; pass < 2; pass++) {
          for (var i = 0; i < _types; i++) {
            final value = await client.read(_variable(i));
            expect(value['Id'].asInt, i);
            expect(value['Label'].asString, 'type $i');
            expectBounded();
          }
        }
      });

      test('readValue (resolved by encoding id) keeps the cache within the cap', () async {
        for (var i = 0; i < _types; i++) {
          final value = (await client.readValue(_variable(i))).value;
          expect(value['Id'].asInt, i);
          expectBounded();
        }
      });

      test('readValue of a type a read cached, across the cap', () async {
        // The read caches the definition; the readValue only adds the
        // encoding-id alias, which on a full cache empties it.
        for (var i = 0; i < _types; i++) {
          expect((await client.read(_variable(i)))['Id'].asInt, i);
          expect((await client.readValue(_variable(i))).value['Id'].asInt, i);
          expectBounded();
        }
      });

      test('concurrent reads across the cap all decode', () async {
        final values = await Future.wait([for (var i = 0; i < _types; i++) client.read(_variable(i))]);
        for (var i = 0; i < _types; i++) {
          expect(values[i]['Id'].asInt, i);
        }
        expectBounded();
      });
    });
  }
}
