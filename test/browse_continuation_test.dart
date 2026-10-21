// Regression test for a double free in Client.browse.
//
// Symptom
//   Browsing a node with more references than the server returns in one
//   response killed the process: glibc aborts with "free(): invalid pointer"
//   or "free(): double free detected in tcache 2", AddressSanitizer reports
//   "heap-use-after-free" / "attempting double-free". Servers that page their
//   Browse answers (a PLC with a few dozen tags in a folder will do) are
//   common; this package's own server never did, so nothing reached the code.
//
// Root cause
//   lib/src/client.dart _browseNext() stores the continuation point in the
//   BrowseNextRequest (request.continuationPoints -> UA_ByteString -> data),
//   which makes both allocations the request's. It then freed the data and the
//   UA_ByteString by hand and deleted the request, whose
//   UA_BrowseNextRequest_delete reads the freed UA_ByteString and frees both
//   again.
//
// What this test asserts
//   A paged browse returns every reference, in order, and the client still
//   works afterwards. A double free takes the whole test runner down, so on
//   the unpatched client this file does not fail an expectation: the run dies
//   in it.

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart' show freeTcpPort;

void main() {
  late Server server;
  late Client client;

  final folderId = NodeId.fromString(1, 'paged.folder');
  const childCount = 7;
  final childNames = [for (var i = 0; i < childCount; i++) 'child$i'];

  /// Drives both event loops until [future] completes.
  Future<T> pump<T>(Future<T> future) async {
    var done = false;
    future.whenComplete(() => done = true).ignore();
    while (!done) {
      server.runIterate();
      client.runIterate(Duration.zero);
      await Future<void>.delayed(Duration.zero);
    }
    return future;
  }

  setUp(() async {
    final port = await freeTcpPort();
    server = Server(port: port, logLevel: LogLevel.UA_LOGLEVEL_FATAL);
    server.start();
    server.addFolderNode(folderId, 'PagedFolder');
    for (final name in childNames) {
      server.addVariableNode(
        NodeId.fromString(1, 'paged.$name'),
        DynamicValue(value: 0, typeId: NodeId.int32, name: name),
        parentNodeId: folderId,
      );
    }

    client = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
    await pump(client.connect('opc.tcp://127.0.0.1:$port'));
  });

  tearDown(() async {
    // The server goes first, and the client gets to see its channel close.
    // Deleting a client whose session is still active waits five seconds for
    // a CloseSession answer that a server pumped by this very isolate cannot
    // give meanwhile.
    server.shutdown();
    for (var i = 0; i < 10; i++) {
      client.runIterate(Duration.zero);
    }
    await client.delete();
    server.delete();
  });

  Future<List<String>> browseChildren() async {
    final references = await pump(
      client.browse(folderId, direction: 0, referenceTypeId: NodeId.hierarchicalReferences),
    );
    return [for (final reference in references) reference.browseName];
  }

  test('a browse answered in one response returns every reference', () async {
    expect(server.maxReferencesPerNode, 0);
    expect(await browseChildren(), childNames);
  });

  for (final pageSize in [1, 3, childCount - 1]) {
    test('a browse answered in pages of $pageSize returns every reference: no crash', () async {
      server.maxReferencesPerNode = pageSize;

      expect(await browseChildren(), childNames);
      // Heap damage often shows only at a later allocation.
      expect(await browseChildren(), childNames, reason: 'the client must still work after a paged browse');
      expect((await pump(client.read(NodeId.fromString(1, 'paged.child0')))).asInt, 0);
    });
  }
}
