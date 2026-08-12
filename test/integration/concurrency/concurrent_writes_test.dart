// CONCURRENCY: concurrent writes to the SAME node from multiple clients.
//
// Several clients hammer one shared node at once. OPC UA write is a serialized
// server-side operation, so the guarantees we assert are:
//   - no corruption: every read ever returns one of the values that was
//     actually written (never a torn/garbage value);
//   - convergence / last-writer-wins: after the dust settles and one final
//     write is applied, every client reads back that same final value.
//
// Uses a deterministic Dart `Server` so the set of legal values is known
// exactly.
@Tags(['integration'])
library;

import 'dart:async';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import '../harness/dart_client.dart';
import '../harness/net.dart';
import 'concurrency_support.dart';

void main() {
  group('concurrent writes to one shared node', () {
    test('N clients hammer a shared double: no corruption, then convergence', () async {
      const clientCount = 4;
      const writesPerClient = 25;
      final port = await freePort();
      final server = await startDartServer(port, seed: (s) => seedPerClientNodes(s, clientCount));
      List<DrivenClient> clients = const [];
      try {
        clients = await connectFleet(server.endpoint, clientCount);

        // Every value any client writes comes from this known set. Client i
        // writes values of the form i*1000 + k, so a read can be attributed and
        // must always be one of the legal values (never torn/garbage).
        bool isLegal(double v) {
          final iv = v.round();
          if ((v - iv).abs() > 1e-6) return false;
          final client = iv ~/ 1000;
          final k = iv % 1000;
          return client >= 0 && client < clientCount && k >= 0 && k < writesPerClient;
        }

        // Interleave writes with reads; assert every observed value is legal.
        final work = <Future<void>>[];
        for (var i = 0; i < clientCount; i++) {
          final client = clients[i].client;
          work.add(() async {
            for (var k = 0; k < writesPerClient; k++) {
              await client.write(
                sharedDoubleNode,
                DynamicValue(value: (i * 1000 + k).toDouble(), typeId: NodeId.double),
              );
              final v = await client.read(sharedDoubleNode);
              expect(isLegal(v.asDouble), isTrue, reason: 'client $i observed corrupt value ${v.asDouble}');
            }
          }());
        }
        await Future.wait(work);

        // Convergence: apply one final authoritative write, then every client
        // (and the server's own view) must agree on it (last-writer-wins).
        const finalValue = 424242.0;
        await clients.first.client.write(sharedDoubleNode, DynamicValue(value: finalValue, typeId: NodeId.double));
        // Small settle margin for the write to be visible to all sessions.
        await Future<void>.delayed(const Duration(milliseconds: 200));

        expect(server.server.read(sharedDoubleNode).asDouble, closeTo(finalValue, 1e-9));
        for (var i = 0; i < clientCount; i++) {
          final v = await clients[i].client.read(sharedDoubleNode);
          expect(v.asDouble, closeTo(finalValue, 1e-9), reason: 'client $i did not converge to last write');
        }
      } finally {
        await disposeFleet(clients);
        await server.stop();
      }
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
}
