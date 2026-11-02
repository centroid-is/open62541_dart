// A ReadResponse carries one result per attribute read, in request order. The
// count was compared with the request only in an assert: a response with
// fewer results left readAttribute with a partial map (assertions off) or
// never completing (on, the assert threw inside the native callback).
//
// DataValueRewritingProxy replaces the results of a two-result ReadResponse
// with a single Good DataValue without a value.

import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'common.dart';
import 'data_value_rewriting_proxy.dart';

/// Offset of the results count in a ReadResponse: message, secure channel and
/// sequence headers (24), the type NodeId (4) and a Good ResponseHeader (24).
const _resultsOffset = 52;

void main() {
  for (final clientType in clientTypes) {
    test('$clientType client: a ReadResponse with fewer results than attributes read fails the read', () async {
      final server = setupServer();
      addBasicVariables(server);
      final proxy = await DataValueRewritingProxy.start(server.port);
      var rewrites = 0;
      proxy.rewriteMessage = (message) {
        if (!isReadResponse(message)) return message;
        if (ByteData.sublistView(message).getInt32(_resultsOffset, Endian.little) != 2) return message;
        rewrites++;
        final out = Uint8List(_resultsOffset + 9)..setRange(0, _resultsOffset, message);
        ByteData.sublistView(out)
          ..setUint32(4, out.length, Endian.little)
          ..setInt32(_resultsOffset, 1, Endian.little) // results: one,
          ..setUint8(_resultsOffset + 4, 0) // a DataValue with no field set,
          ..setInt32(_resultsOffset + 5, -1, Endian.little); // no diagnostics
        return out;
      };
      final client = await setupClientOfType(clientType, 'opc.tcp://127.0.0.1:${proxy.port}');

      await expectLater(
        client
            .readAttribute({
              intNodeId: [AttributeId.UA_ATTRIBUTEID_DISPLAYNAME, AttributeId.UA_ATTRIBUTEID_DESCRIPTION],
            })
            .timeout(const Duration(seconds: 10)),
        throwsA(predicate<Object>((e) => '$e'.contains('BadUnexpectedError'), 'Bad_UnexpectedError')),
      );
      expect(rewrites, 1);

      await client.delete();
      await proxy.close();
      server.shutdown();
      server.delete();
    });
  }
}
