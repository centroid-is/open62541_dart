// A CreateSubscription the server refuses (here BadTooManySubscriptions,
// written into the response by a proxy) failed with a plain String, so a
// caller could not read the status code. It is now a UaStatusException, on
// Client and, across the isolate boundary, on ClientIsolate.

import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'common.dart';
import 'data_value_rewriting_proxy.dart';

const _createSubscriptionResponse = 790;

void main() {
  for (final clientType in clientTypes) {
    test('$clientType: a refused CreateSubscription is a UaStatusException with the status', () async {
      final server = setupServer();
      addBasicVariables(server);
      addTearDown(() {
        server.shutdown();
        server.delete();
      });
      final proxy = await DataValueRewritingProxy.start(server.port);
      addTearDown(proxy.close);

      var refuse = false;
      var rewrites = 0;
      proxy.rewriteMessage = (message) {
        final view = ByteData.sublistView(message);
        if (!refuse || message.length < 44 || view.getUint16(26, Endian.little) != _createSubscriptionResponse) {
          return message;
        }
        // serviceResult of the ResponseHeader.
        final out = Uint8List.fromList(message);
        ByteData.sublistView(out).setUint32(40, raw.UA_STATUSCODE_BADTOOMANYSUBSCRIPTIONS, Endian.little);
        rewrites++;
        return out;
      };

      final client = await setupClientOfType(clientType, 'opc.tcp://127.0.0.1:${proxy.port}');
      addTearDown(client.delete);

      final first = await client.subscriptionCreate(requestedPublishingInterval: const Duration(milliseconds: 50));
      refuse = true;
      await expectLater(
        client.subscriptionCreate(),
        throwsA(
          isA<UaStatusException>().having((e) => e.statusCode, 'statusCode', raw.UA_STATUSCODE_BADTOOMANYSUBSCRIPTIONS),
        ),
      );
      expect(rewrites, 1);
      refuse = false;

      // The first subscription still delivers.
      final stream = client.monitoredItems({
        intNodeId: [AttributeId.UA_ATTRIBUTEID_VALUE],
      }, first);
      expect(await stream.first.timeout(const Duration(seconds: 10)), isNotNull);
    }, timeout: const Timeout(Duration(seconds: 30)));
  }
}
