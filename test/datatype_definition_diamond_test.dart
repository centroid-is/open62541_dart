// Client.buildSchema reads each distinct DataType of a structured value once.
// It used to read a type again for every field that named it, so a diamond,
// D0 {a: D1, b: D1}, D1 {a: D2, b: D2}, ..., cost one readAttribute per path,
// 2^(k+1) for k levels: k = 16 did not finish in a minute. A type that needs
// more definitions than schemaCacheSize is refused with
// DataTypeDefinitionTooMany instead of being fetched.
//
// The ReadResponses are counted by a DataValueRewritingProxy in front of the
// server.

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart';
import 'data_value_rewriting_proxy.dart';

const _k = 16;
NodeId _dia(int i) => NodeId.fromString(1, 'Dia$i');
final _diaNode = NodeId.fromString(1, 'dia.node');
final _wideType = NodeId.fromString(1, 'Wide');
final _wideNode = NodeId.fromString(1, 'wide.node');
final _topType = NodeId.fromString(1, 'Top');
final _topNode = NodeId.fromString(1, 'top.node');

/// Registers the diamond D0..Dk on [server] and returns D0's value.
DynamicValue addDiamond(Server server, int k) {
  final values = <int, DynamicValue>{};
  for (var i = k; i >= 0; i--) {
    final v = DynamicValue(name: 'Dia$i', typeId: _dia(i));
    if (i == k) {
      v['x'] = DynamicValue(value: 1, typeId: NodeId.int32);
    } else {
      v['a'] = values[i + 1]!;
      v['b'] = values[i + 1]!;
    }
    values[i] = v;
  }
  for (var i = k; i >= 0; i--) {
    server.addCustomType(_dia(i), values[i]!);
    server.addDataTypeNode(_dia(i), 'Dia$i');
  }
  return values[0]!;
}

void main() {
  for (final clientType in clientTypes) {
    group('$clientType client: DataTypeDefinitions shared by several fields', () {
      late Server server;
      late DataValueRewritingProxy proxy;
      var reads = 0;
      final clients = <ClientApi>[];

      Future<ClientApi> connect({int schemaCacheSize = Client.defaultSchemaCacheSize}) async {
        final client = await setupClientOfType(
          clientType,
          'opc.tcp://127.0.0.1:${proxy.port}',
          schemaCacheSize: schemaCacheSize,
        );
        clients.add(client);
        reads = 0;
        return client;
      }

      setUp(() async {
        server = setupServer();
        final d0 = addDiamond(server, _k);
        server.addVariableNode(_diaNode, d0, typeId: _dia(0));
        // Top {d: D1}: a new type whose field's type an earlier read cached.
        final top = DynamicValue(name: 'Top', typeId: _topType);
        top['d'] = d0['a'];
        server.addCustomType(_topType, top);
        server.addDataTypeNode(_topType, 'Top');
        server.addVariableNode(_topNode, top, typeId: _topType);
        // Wide {f0: W0, ..., f19: W19}: twenty distinct struct types.
        final wide = DynamicValue(name: 'Wide', typeId: _wideType);
        for (var i = 0; i < 20; i++) {
          final type = NodeId.fromString(1, 'W$i');
          final leaf = DynamicValue(name: 'W$i', typeId: type);
          leaf['x'] = DynamicValue(value: i, typeId: NodeId.int32);
          server.addCustomType(type, leaf);
          server.addDataTypeNode(type, 'W$i');
          wide['f$i'] = leaf;
        }
        server.addCustomType(_wideType, wide);
        server.addDataTypeNode(_wideType, 'Wide');
        server.addVariableNode(_wideNode, wide, typeId: _wideType);
        proxy = await DataValueRewritingProxy.start(server.port);
        proxy.rewriteMessage = (message) {
          if (isReadResponse(message)) reads++;
          return message;
        };
      });

      tearDown(() async {
        for (final client in clients) {
          await client.delete();
        }
        clients.clear();
        await proxy.close();
        server.shutdown();
        server.delete();
      });

      test('a diamond of $_k levels costs a read per type, not per path', () async {
        final client = await connect();
        final value = await client.read(_diaNode);
        var leaf = value;
        for (var i = 0; i < _k; i++) {
          leaf = leaf[i.isEven ? 'a' : 'b'];
        }
        expect(leaf['x'].asInt, 1);
        expect(reads, lessThan(_k + 5));

        reads = 0;
        expect((await client.read(_topNode))['d']['a']['b'].isObject, isTrue);
        expect(reads, lessThan(4));
      }, timeout: const Timeout(Duration(seconds: 60)));

      test('a type needing more definitions than schemaCacheSize is refused', () async {
        final client = await connect(schemaCacheSize: 5);
        await expectLater(
          client.read(_wideNode),
          throwsA(
            predicate<Object>(
              (e) => '$e'.contains('DataTypeDefinitionTooMany') && '$e'.contains('more than 5 types'),
              'DataTypeDefinitionTooMany',
            ),
          ),
        );
        expect(reads, lessThan(8));
        // The client is still usable.
        expect((await client.read(NodeId.fromNumeric(0, 2259))).isNull, isFalse);
      });
    });
  }
}
