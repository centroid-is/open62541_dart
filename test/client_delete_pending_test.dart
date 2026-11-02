// Client.delete() frees the native client while an operation may still be
// under way: a read building its schema one definition at a time, a browse
// following continuation points, a connect waiting for its session. The next
// service call of such an operation passed the freed (null) client to
// open62541 and the process died in __UA_Client_AsyncService (SIGSEGV), and
// a connect or awaitConnect waiting on the state stream failed with
// StateError("No element") when delete() closed it.
//
// Now every service call checks the client first and fails with
// ClientDeletedException, and so do connect and awaitConnect (for
// ClientIsolate: its subtype ClientIsolateClosedException).

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart';
import 'data_value_rewriting_proxy.dart';

const _levels = 90;
NodeId _chainType(int level) => NodeId.fromString(1, 'Chain$level');
final _chainNode = NodeId.fromString(1, 'chain.node');

/// Chain0 {next: Chain1}, ..., {leaf: Boolean}: one definition read per level.
DynamicValue _chain(Server server, int level) {
  final v = DynamicValue(name: 'Chain$level', typeId: _chainType(level));
  if (level == _levels - 1) {
    v['leaf'] = DynamicValue(value: true, typeId: NodeId.boolean);
  } else {
    v['next'] = _chain(server, level + 1);
  }
  return v;
}

Future<ClientApi> _unconnected(String clientType) async {
  if (clientType == 'isolate') return ClientIsolate.create(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
  final client = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
  () async {
    while (client.runIterate(const Duration(milliseconds: 10))) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }();
  return client;
}

/// The error [future] completes with, or 'none' when it completes with a value.
Future<Object> _errorOf(Future<Object?> future) => future.then<Object>((_) => 'none', onError: (Object e) => e);

void main() {
  for (final clientType in clientTypes) {
    group('$clientType client: delete() while an operation is under way', () {
      test('a read building its schema ends with an error, the process survives', () async {
        final server = setupServer();
        final root = _chain(server, 0);
        server.addCustomType(_chainType(0), root);
        server.addDataTypeNode(_chainType(0), 'Chain0');
        server.addVariableNode(_chainNode, root, typeId: _chainType(0));
        final proxy = await DataValueRewritingProxy.start(server.port);
        final fiveReads = Completer<void>();
        var reads = 0;
        proxy.rewriteMessage = (message) {
          if (isReadResponse(message) && ++reads == 5) fiveReads.complete();
          return message;
        };
        final client = await setupClientOfType(clientType, 'opc.tcp://127.0.0.1:${proxy.port}');
        reads = 0;

        final error = _errorOf(client.read(_chainNode));
        await fiveReads.future;
        await client.delete();
        final e = await error.timeout(const Duration(seconds: 10));
        expect(e, isA<ClientDeletedException>());

        // Still alive: the definitions the read would have fetched next would
        // have been requested through the freed client by now.
        await Future<void>.delayed(const Duration(seconds: 1));
        expect(reads, lessThan(_levels));
        await proxy.close();
        server.shutdown();
        server.delete();
      });

      test('a connect waiting for its session ends with ClientDeletedException', () async {
        // Accepts and never answers: the handshake stays pending.
        final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final held = <Socket>[];
        listener.listen(held.add);
        final client = await _unconnected(clientType);
        final connect = _errorOf(client.connect('opc.tcp://127.0.0.1:${listener.port}'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final awaitConnect = _errorOf(client.awaitConnect());
        await client.delete();
        final connectError = await connect.timeout(const Duration(seconds: 10));
        final awaitError = await awaitConnect.timeout(const Duration(seconds: 10));
        expect(connectError, isA<ClientDeletedException>());
        expect(awaitError, isA<ClientDeletedException>());
        await listener.close();
        for (final socket in held) {
          socket.destroy();
        }
      });

      test('calls after delete() fail with ClientDeletedException', () async {
        final server = setupServer();
        addBasicVariables(server);
        final client = await setupClientOfType(clientType, 'opc.tcp://127.0.0.1:${server.port}');
        await client.delete();
        for (final call in <Future<Object?> Function()>[
          () => client.read(NodeId.fromNumeric(0, 2259)),
          () => client.browse(NodeId.objectsFolder),
          () => client.connect('opc.tcp://127.0.0.1:${server.port}'),
        ]) {
          final e = await _errorOf(call());
          expect(e, isA<ClientDeletedException>());
        }
        server.shutdown();
        server.delete();
      });
    });
  }
}
