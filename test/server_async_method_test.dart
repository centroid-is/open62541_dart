import 'dart:async';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'common.dart';

/// Async method callbacks (backlog item 3) and multi-output marshalling
/// (item 4). The handler is `Future`-returning: the call is parked as an
/// open62541 async operation and answered when the future completes, so a
/// handler can genuinely await (I/O, engine commits, ...) without blocking
/// the server's iterate loop.
void main() {
  group('Async server methods', () {
    late int port;
    late Server server;
    late Client client;

    setUp(() async {
      port = await freeTcpPort();
      server = setupServer(port);
      client = await setupClient(port);
    });

    tearDown(() async {
      await client.delete();
      server.shutdown();
      server.delete();
    });

    test('a genuinely awaiting handler returns the awaited result', () async {
      final methodId = NodeId.fromString(1, 'method.slow');
      server.addMethodNode(
        methodId,
        browseName: 'slow',
        inputArguments: [Argument(name: 'x', dataType: NodeId.int32)],
        outputArguments: [Argument(name: 'out', dataType: NodeId.int32)],
        callback: (inputs, session) async {
          // A real await — several server iterate ticks pass before the
          // result exists.
          await Future.delayed(const Duration(milliseconds: 300));
          return [DynamicValue(value: inputs[0].asInt * 2, typeId: NodeId.int32)];
        },
      );

      final result = await client.call(NodeId.objectsFolder, methodId, [DynamicValue(value: 21, typeId: NodeId.int32)]);
      expect(result.single.asInt, 42);
    });

    test('concurrent in-flight calls complete independently', () async {
      // One method, staggered completion times; both calls are in flight at
      // once and each caller gets its own result.
      final completers = <int, Completer<void>>{1: Completer(), 2: Completer()};
      final methodId = NodeId.fromString(1, 'method.gated');
      server.addMethodNode(
        methodId,
        browseName: 'gated',
        inputArguments: [Argument(name: 'id', dataType: NodeId.int32)],
        outputArguments: [Argument(name: 'out', dataType: NodeId.int32)],
        callback: (inputs, session) async {
          final id = inputs[0].asInt;
          await completers[id]!.future;
          return [DynamicValue(value: id * 100, typeId: NodeId.int32)];
        },
      );

      final call1 = client.call(NodeId.objectsFolder, methodId, [DynamicValue(value: 1, typeId: NodeId.int32)]);
      final call2 = client.call(NodeId.objectsFolder, methodId, [DynamicValue(value: 2, typeId: NodeId.int32)]);
      // Let both requests reach the server and park before releasing them in
      // reverse order.
      await Future.delayed(const Duration(milliseconds: 300));
      completers[2]!.complete();
      expect((await call2).single.asInt, 200);
      completers[1]!.complete();
      expect((await call1).single.asInt, 100);
    });

    test('a UaStatusException from the handler reaches the caller as that code', () async {
      final methodId = NodeId.fromString(1, 'method.denied');
      server.addMethodNode(
        methodId,
        browseName: 'denied',
        outputArguments: [Argument(name: 'out', dataType: NodeId.int32)],
        callback: (inputs, session) async {
          await Future.delayed(const Duration(milliseconds: 50));
          throw UaStatusException(raw.UA_STATUSCODE_BADUSERACCESSDENIED);
        },
      );

      await expectLater(
        client.call(NodeId.objectsFolder, methodId, const []),
        throwsA(predicate((e) => e.toString().contains('BadUserAccessDenied'), 'mentions BadUserAccessDenied')),
      );
    });

    test('all three outputs of a 3-output method reach the caller, typed', () async {
      // Regression for item 4: only output[0] used to survive — the client's
      // async response callback read outputs 1.. after open62541 had freed
      // the CallResponse.
      final methodId = NodeId.fromString(1, 'method.triple');
      server.addMethodNode(
        methodId,
        browseName: 'triple',
        inputArguments: [Argument(name: 'x', dataType: NodeId.int32)],
        outputArguments: [
          Argument(name: 'doubled', dataType: NodeId.int32),
          Argument(name: 'label', dataType: NodeId.uastring),
          Argument(name: 'half', dataType: NodeId.double),
        ],
        callback: (inputs, session) async {
          final x = inputs[0].asInt;
          return [
            DynamicValue(value: x * 2, typeId: NodeId.int32),
            DynamicValue(value: 'x=$x', typeId: NodeId.uastring),
            DynamicValue(value: x / 2, typeId: NodeId.double),
          ];
        },
      );

      final result = await client.call(NodeId.objectsFolder, methodId, [DynamicValue(value: 7, typeId: NodeId.int32)]);
      expect(result, hasLength(3));
      expect(result[0].asInt, 14);
      expect(result[1].asString, 'x=7');
      expect(result[2].asDouble, closeTo(3.5, 1e-9));
    });

    test('a 0-output method completes', () async {
      var invoked = false;
      final methodId = NodeId.fromString(1, 'method.void');
      server.addMethodNode(
        methodId,
        browseName: 'void',
        callback: (inputs, session) async {
          await Future.delayed(const Duration(milliseconds: 50));
          invoked = true;
          return const [];
        },
      );

      final result = await client.call(NodeId.objectsFolder, methodId, const []);
      expect(result, isEmpty);
      expect(invoked, isTrue);
    });

    test('session info is captured for async handlers (valid after awaits)', () async {
      MethodSessionInfo? captured;
      final methodId = NodeId.fromString(1, 'method.who.async');
      server.addMethodNode(
        methodId,
        browseName: 'who.async',
        outputArguments: [Argument(name: 'out', dataType: NodeId.int32)],
        callback: (inputs, session) async {
          // The info was resolved at invocation time; it must survive awaits.
          await Future.delayed(const Duration(milliseconds: 100));
          captured = session;
          return [DynamicValue(value: 1, typeId: NodeId.int32)];
        },
      );

      await client.call(NodeId.objectsFolder, methodId, const []);
      final info = captured!;
      expect(info.sessionId.isGuid(), isTrue);
      expect(info.identity, isA<AnonymousSessionIdentity>());
      expect(info.applicationUri, isNotEmpty);
    });
  });

  group('Call service faults', () {
    // Own lifecycle: the test kills the server itself, so no shared tearDown
    // may shut it down a second time.
    late Server server;
    late Client client;

    setUp(() async {
      final port = await freeTcpPort();
      server = setupServer(port);
      client = await setupClient(port);
    });

    tearDown(() async {
      await client.delete();
    });

    test('a call in flight when the server dies surfaces the service status', () async {
      // Regression for the CI flake signature "No results for call to ...":
      // when the connection drops, the client answers the pending request with
      // a synthesized response — serviceResult set, zero results. The handler
      // used to check resultsSize first and report a misleading "No results";
      // it must surface the real status as a typed UaStatusException.
      final methodId = NodeId.fromString(1, 'method.parked');
      server.addMethodNode(
        methodId,
        browseName: 'parked',
        outputArguments: [Argument(name: 'out', dataType: NodeId.int32)],
        callback: (inputs, session) async {
          // Park forever; the server dies before this would ever complete.
          await Completer<void>().future;
          return [DynamicValue(value: 0, typeId: NodeId.int32)];
        },
      );

      final call = client.call(NodeId.objectsFolder, methodId, const []);
      // Let the request reach the server and park as an async operation.
      await Future.delayed(const Duration(milliseconds: 300));
      server.shutdown();
      server.delete();

      await expectLater(call, throwsA(isA<UaStatusException>()));
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}
