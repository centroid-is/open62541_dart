import 'dart:async';
import 'dart:math';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart';

/// Creates a unique NodeId for a given server index and variable index.
NodeId nodeIdFor(int serverIndex, int varIndex) => NodeId.fromString(1, "srv${serverIndex}_var$varIndex");

void main() {
  group('Multi-server stress tests', () {
    final basePort = Random().nextInt(8000) + 20000;
    final serverCount = 4;
    final servers = <Server>[];
    final clients = <Client>[];

    setUp(() async {
      servers.clear();
      clients.clear();
      for (var i = 0; i < serverCount; i++) {
        servers.add(setupServer(basePort + i));
      }
      for (var i = 0; i < serverCount; i++) {
        clients.add(await setupClient(basePort + i));
      }
    });

    tearDown(() async {
      for (final c in clients) {
        await c.delete();
      }
      stopServerLoop();
      await Future.delayed(Duration(milliseconds: 20));
      for (final s in servers) {
        s.shutdown();
        s.delete();
      }
      servers.clear();
      clients.clear();
    });

    test('rapid writes across 4 servers', () async {
      const varsPerServer = 20;
      for (var s = 0; s < serverCount; s++) {
        for (var v = 0; v < varsPerServer; v++) {
          servers[s].addVariableNode(
            nodeIdFor(s, v),
            DynamicValue(value: 0, typeId: NodeId.int32, name: "srv${s}_var$v"),
          );
        }
      }

      // Each client writes 20 values to its server concurrently
      final futures = <Future>[];
      for (var s = 0; s < serverCount; s++) {
        for (var v = 0; v < varsPerServer; v++) {
          futures.add(clients[s].write(nodeIdFor(s, v), DynamicValue(value: (s + 1) * 100 + v, typeId: NodeId.int32)));
        }
      }
      await Future.wait(futures);

      // Read back all values
      for (var s = 0; s < serverCount; s++) {
        for (var v = 0; v < varsPerServer; v++) {
          final result = await clients[s].read(nodeIdFor(s, v));
          expect(result.value, (s + 1) * 100 + v, reason: 'Server $s, var $v mismatch');
        }
      }
    });

    test('cross-server replication under load', () async {
      const varCount = 10;

      for (var v = 0; v < varCount; v++) {
        servers[0].addVariableNode(
          nodeIdFor(0, v),
          DynamicValue(value: v * 10, typeId: NodeId.int32, name: "src_var$v"),
        );
      }

      // Client 0 reads all values from source
      final readFutures = <Future<DynamicValue>>[];
      for (var v = 0; v < varCount; v++) {
        readFutures.add(clients[0].read(nodeIdFor(0, v)));
      }
      final sourceValues = await Future.wait(readFutures);

      // Replicate to all other servers
      for (var s = 1; s < serverCount; s++) {
        for (var v = 0; v < varCount; v++) {
          servers[s].addVariableNode(
            nodeIdFor(0, v),
            DynamicValue(value: sourceValues[v].value, typeId: sourceValues[v].typeId, name: "src_var$v"),
          );
        }
      }

      // All replica clients read back and verify
      for (var s = 1; s < serverCount; s++) {
        for (var v = 0; v < varCount; v++) {
          final result = await clients[s].read(nodeIdFor(0, v));
          expect(result.value, v * 10, reason: 'Replica server $s, var $v mismatch');
        }
      }
    });

    test('concurrent reads from all 4 servers simultaneously', () async {
      for (var s = 0; s < serverCount; s++) {
        servers[s].addVariableNode(
          NodeId.fromString(1, "bool_$s"),
          DynamicValue(value: s.isEven, typeId: NodeId.boolean, name: "bool_$s"),
        );
        servers[s].addVariableNode(
          NodeId.fromString(1, "int_$s"),
          DynamicValue(value: s * 100, typeId: NodeId.int32, name: "int_$s"),
        );
        servers[s].addVariableNode(
          NodeId.fromString(1, "dbl_$s"),
          DynamicValue(value: s * 1.5, typeId: NodeId.double, name: "dbl_$s"),
        );
        servers[s].addVariableNode(
          NodeId.fromString(1, "str_$s"),
          DynamicValue(value: "server_$s", typeId: NodeId.uastring, name: "str_$s"),
        );
      }

      // Fire all reads concurrently across all servers
      final allReads = <Future<DynamicValue>>[];
      for (var s = 0; s < serverCount; s++) {
        allReads.add(clients[s].read(NodeId.fromString(1, "bool_$s")));
        allReads.add(clients[s].read(NodeId.fromString(1, "int_$s")));
        allReads.add(clients[s].read(NodeId.fromString(1, "dbl_$s")));
        allReads.add(clients[s].read(NodeId.fromString(1, "str_$s")));
      }
      final results = await Future.wait(allReads);

      for (var s = 0; s < serverCount; s++) {
        final base = s * 4;
        expect(results[base].value, s.isEven, reason: 'bool server $s');
        expect(results[base + 1].value, s * 100, reason: 'int server $s');
        expect((results[base + 2].value as double), closeTo(s * 1.5, 0.001), reason: 'double server $s');
        expect(results[base + 3].value, "server_$s", reason: 'string server $s');
      }
    });

    test('write-read storm: many rapid writes then bulk read', () async {
      final nodeId = NodeId.fromNumeric(1, 9999);
      const iterations = 20;

      for (var s = 0; s < serverCount; s++) {
        servers[s].addVariableNode(nodeId, DynamicValue(value: 0, typeId: NodeId.int32, name: "storm"));
      }

      // Rapid writes per server, all servers in parallel
      final writeFutures = <Future>[];
      for (var s = 0; s < serverCount; s++) {
        writeFutures.add(() async {
          for (var i = 0; i < iterations; i++) {
            await clients[s].write(nodeId, DynamicValue(value: i, typeId: NodeId.int32));
          }
        }());
      }
      await Future.wait(writeFutures);

      // All should have the last written value
      for (var s = 0; s < serverCount; s++) {
        final result = await clients[s].read(nodeId);
        expect(result.value, iterations - 1, reason: 'Server $s should have last written value');
      }
    });

    test('browse all 4 servers concurrently', () async {
      for (var s = 0; s < serverCount; s++) {
        for (var v = 0; v < (s + 1) * 3; v++) {
          servers[s].addVariableNode(
            NodeId.fromString(1, "browse_s${s}_v$v"),
            DynamicValue(value: v, typeId: NodeId.int32, name: "s${s}_v$v"),
          );
        }
      }

      // Browse all servers concurrently
      final browseFutures = <Future<List<BrowseResultItem>>>[];
      for (var s = 0; s < serverCount; s++) {
        browseFutures.add(clients[s].browse(NodeId.objectsFolder));
      }
      final browseResults = await Future.wait(browseFutures);

      for (var s = 0; s < serverCount; s++) {
        final vars = browseResults[s].where((r) => r.nodeClass == NodeClass.UA_NODECLASS_VARIABLE).toList();
        expect(
          vars.length,
          greaterThanOrEqualTo((s + 1) * 3),
          reason: 'Server $s should have at least ${(s + 1) * 3} variables',
        );
      }
    });

    test('monitor + write across multiple servers simultaneously', () async {
      final nodeA = NodeId.fromString(1, "monitor_a");
      final nodeB = NodeId.fromString(1, "monitor_b");

      servers[0].addVariableNode(nodeA, DynamicValue(value: 0, typeId: NodeId.int32, name: "monitor_a"));
      servers[1].addVariableNode(nodeB, DynamicValue(value: 0, typeId: NodeId.int32, name: "monitor_b"));

      final subA = await clients[0].subscriptionCreate(requestedPublishingInterval: Duration(milliseconds: 10));
      final subB = await clients[1].subscriptionCreate(requestedPublishingInterval: Duration(milliseconds: 10));

      final valuesA = <int>[];
      final valuesB = <int>[];
      final completerA = Completer<void>();
      final completerB = Completer<void>();

      final streamA = clients[0].monitor(nodeA, subA, samplingInterval: Duration(milliseconds: 10));
      final streamB = clients[1].monitor(nodeB, subB, samplingInterval: Duration(milliseconds: 10));

      final listenA = streamA.listen((data) {
        valuesA.add(data.value as int);
        if (valuesA.length >= 4 && !completerA.isCompleted) {
          completerA.complete();
        }
      });
      final listenB = streamB.listen((data) {
        valuesB.add(data.value as int);
        if (valuesB.length >= 4 && !completerB.isCompleted) {
          completerB.complete();
        }
      });

      await Future.delayed(Duration(milliseconds: 200));

      for (var i = 1; i <= 3; i++) {
        await clients[0].write(nodeA, DynamicValue(value: i, typeId: NodeId.int32));
        await clients[1].write(nodeB, DynamicValue(value: i * 10, typeId: NodeId.int32));
        await Future.delayed(Duration(milliseconds: 100));
      }

      await completerA.future.timeout(Duration(seconds: 5));
      await completerB.future.timeout(Duration(seconds: 5));

      await listenA.cancel();
      await listenB.cancel();

      expect(valuesA.length, greaterThanOrEqualTo(4));
      expect(valuesB.length, greaterThanOrEqualTo(4));
      expect(valuesA.last, 3);
      expect(valuesB.last, 30);
    });

    test('readAttribute bulk across multiple servers', () async {
      for (var s = 0; s < serverCount; s++) {
        servers[s].addVariableNode(
          NodeId.fromString(1, "attr_$s"),
          DynamicValue(value: s * 42, typeId: NodeId.int32, name: "attr_var_$s"),
        );
        await servers[s].writeAttribute(
          NodeId.fromString(1, "attr_$s"),
          AttributeId.UA_ATTRIBUTEID_DESCRIPTION,
          LocalizedText("Desc for server $s", ""),
        );
      }

      final attrFutures = <Future<Map<NodeId, DynamicValue>>>[];
      for (var s = 0; s < serverCount; s++) {
        attrFutures.add(
          clients[s].readAttribute({
            NodeId.fromString(1, "attr_$s"): [
              AttributeId.UA_ATTRIBUTEID_VALUE,
              AttributeId.UA_ATTRIBUTEID_DISPLAYNAME,
              AttributeId.UA_ATTRIBUTEID_DESCRIPTION,
              AttributeId.UA_ATTRIBUTEID_DATATYPE,
            ],
          }),
        );
      }
      final attrResults = await Future.wait(attrFutures);

      for (var s = 0; s < serverCount; s++) {
        final data = attrResults[s][NodeId.fromString(1, "attr_$s")]!;
        expect(data.value, s * 42, reason: 'Value server $s');
        expect(data.description!.value, "Desc for server $s", reason: 'Description server $s');
        expect(data.displayName!.value, "attr_var_$s", reason: 'DisplayName server $s');
      }
    });

    test('fan-out: one source server, 3 clients replicate to their servers', () async {
      const varCount = 8;
      for (var v = 0; v < varCount; v++) {
        servers[0].addVariableNode(
          NodeId.fromString(1, "fanout_$v"),
          DynamicValue(value: v * 7, typeId: NodeId.int32, name: "fanout_$v"),
        );
      }

      final readMap = <NodeId, List<AttributeId>>{};
      for (var v = 0; v < varCount; v++) {
        readMap[NodeId.fromString(1, "fanout_$v")] = [
          AttributeId.UA_ATTRIBUTEID_VALUE,
          AttributeId.UA_ATTRIBUTEID_DATATYPE,
        ];
      }
      final sourceData = await clients[0].readAttribute(readMap);

      // Replicate to servers 1, 2, 3
      for (var s = 1; s < serverCount; s++) {
        for (var v = 0; v < varCount; v++) {
          final nid = NodeId.fromString(1, "fanout_$v");
          final dv = sourceData[nid]!;
          servers[s].addVariableNode(nid, DynamicValue(value: dv.value, typeId: dv.typeId, name: "fanout_$v"));
        }
      }

      // Update source values
      for (var v = 0; v < varCount; v++) {
        await servers[0].write(NodeId.fromString(1, "fanout_$v"), DynamicValue(value: v * 100, typeId: NodeId.int32));
      }

      // Propagate updates to replicas
      final updatedData = await clients[0].readAttribute(readMap);
      for (var s = 1; s < serverCount; s++) {
        for (var v = 0; v < varCount; v++) {
          final nid = NodeId.fromString(1, "fanout_$v");
          final dv = updatedData[nid]!;
          await servers[s].write(nid, DynamicValue(value: dv.value, typeId: dv.typeId));
        }
      }

      // Verify all replicas have updated values
      final verifyFutures = <Future>[];
      for (var s = 1; s < serverCount; s++) {
        for (var v = 0; v < varCount; v++) {
          verifyFutures.add(
            clients[s].read(NodeId.fromString(1, "fanout_$v")).then((result) {
              expect(result.value, v * 100, reason: 'Replica server $s, var $v after update');
            }),
          );
        }
      }
      await Future.wait(verifyFutures);
    });

    test('mixed types stress: bool, int, double, string across all servers', () async {
      for (var s = 0; s < serverCount; s++) {
        servers[s].addVariableNode(
          NodeId.fromString(1, "mt_bool_$s"),
          DynamicValue(value: s.isOdd, typeId: NodeId.boolean, name: "mt_bool_$s"),
        );
        servers[s].addVariableNode(
          NodeId.fromString(1, "mt_int_$s"),
          DynamicValue(value: s * 111, typeId: NodeId.int32, name: "mt_int_$s"),
        );
        servers[s].addVariableNode(
          NodeId.fromString(1, "mt_dbl_$s"),
          DynamicValue(value: s * 2.718, typeId: NodeId.double, name: "mt_dbl_$s"),
        );
        servers[s].addVariableNode(
          NodeId.fromString(1, "mt_str_$s"),
          DynamicValue(value: "payload_$s" * 10, typeId: NodeId.uastring, name: "mt_str_$s"),
        );
      }

      // Rapid fire writes
      final writeFutures = <Future>[];
      for (var s = 0; s < serverCount; s++) {
        writeFutures.add(
          clients[s].write(NodeId.fromString(1, "mt_bool_$s"), DynamicValue(value: s.isEven, typeId: NodeId.boolean)),
        );
        writeFutures.add(
          clients[s].write(NodeId.fromString(1, "mt_int_$s"), DynamicValue(value: s * 999, typeId: NodeId.int32)),
        );
        writeFutures.add(
          clients[s].write(NodeId.fromString(1, "mt_dbl_$s"), DynamicValue(value: s * 3.14159, typeId: NodeId.double)),
        );
        writeFutures.add(
          clients[s].write(
            NodeId.fromString(1, "mt_str_$s"),
            DynamicValue(value: "updated_$s" * 5, typeId: NodeId.uastring),
          ),
        );
      }
      await Future.wait(writeFutures);

      // Bulk read everything back concurrently
      final readFutures = <Future<DynamicValue>>[];
      for (var s = 0; s < serverCount; s++) {
        readFutures.add(clients[s].read(NodeId.fromString(1, "mt_bool_$s")));
        readFutures.add(clients[s].read(NodeId.fromString(1, "mt_int_$s")));
        readFutures.add(clients[s].read(NodeId.fromString(1, "mt_dbl_$s")));
        readFutures.add(clients[s].read(NodeId.fromString(1, "mt_str_$s")));
      }
      final results = await Future.wait(readFutures);

      for (var s = 0; s < serverCount; s++) {
        final base = s * 4;
        expect(results[base].value, s.isEven, reason: 'bool after write s=$s');
        expect(results[base + 1].value, s * 999, reason: 'int after write s=$s');
        expect((results[base + 2].value as double), closeTo(s * 3.14159, 0.001), reason: 'double after write s=$s');
        expect(results[base + 3].value, "updated_$s" * 5, reason: 'string after write s=$s');
      }
    });
  }, timeout: Timeout(Duration(seconds: 60)));
}
