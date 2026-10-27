import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'common.dart';
import 'security_harness.dart';

const _clientUri = 'urn:open62541.dart.test.dssession.client';
final _node = NodeId.fromString(1, 'ds.session');

class _Operator {
  const _Operator(this.name);
  final String name;
}

/// Logs in `operator`/`secret` with an [_Operator] context, and anonymous
/// sessions with the context `anonymous`.
class _LoginAccessControl extends AccessControl {
  final contexts = <Object>[];

  @override
  Set<UserTokenType> get userTokenTypes => {UserTokenType.anonymous, UserTokenType.username};

  @override
  Object? activateSession(SessionActivation activation) {
    if (activation.tokenType == UserTokenType.anonymous) return 'anonymous';
    if (activation.username != 'operator' || utf8.decode(activation.password!) != 'secret') {
      throw const UaStatusException(raw.UA_STATUSCODE_BADUSERACCESSDENIED);
    }
    final context = _Operator(activation.username!);
    contexts.add(context);
    return context;
  }
}

/// Runs [future] while pumping [client].
Future<T> pumped<T>(Client client, Future<T> future) async {
  var done = false;
  future.whenComplete(() => done = true).ignore();
  while (!done) {
    client.runIterate(Duration.zero);
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  return future;
}

Matcher _status(int code) => isA<UaStatusException>().having((e) => e.statusCode, 'statusCode', code);

void main() {
  group('unsecured server', () {
    late Server server;
    late Client client;
    var stored = 0;
    final reads = <SessionInfo>[];
    final writes = <(int, SessionInfo)>[];

    /// The session a method call reports, to compare the data-source info with.
    Future<SessionInfo> callerOf(ClientApi api) async {
      final method = NodeId.fromString(1, 'ds.session.whoami');
      final sessions = <SessionInfo>[];
      server.addMethodNode(
        method,
        callback: (inputs, session) async {
          sessions.add(session);
          return [];
        },
      );
      await api.call(NodeId.fromNumeric(0, raw.UA_NS0ID_OBJECTSFOLDER), method, []);
      return sessions.single;
    }

    setUp(() async {
      stored = 0;
      reads.clear();
      writes.clear();
      server = setupServer();
      server.addDataSourceVariableNode(
        _node,
        browseName: 'ds.session',
        typeId: NodeId.int32,
        onReadWithSession: (session) {
          reads.add(session);
          return DataSourceValue(
            value: DynamicValue(value: stored, typeId: NodeId.int32),
          );
        },
        onWriteWithSession: (value, session) async {
          writes.add((value.asInt!, session));
          stored = value.asInt!;
        },
      );
      client = await setupClient(server.port);
    });

    tearDown(() async {
      await client.delete();
      server.shutdown();
      server.delete();
    });

    test('a client write and read see the client session', () async {
      final caller = await callerOf(client);
      await client.write(_node, DynamicValue(value: 7, typeId: NodeId.int32));
      final (value, writer) = writes.single;
      expect(value, 7);
      expect(writer.sessionId, caller.sessionId);
      expect(writer.isAdminSession, isFalse);
      expect(writer.identity, isA<AnonymousSessionIdentity>());
      expect(writer.sessionName, caller.sessionName);
      expect(writer.applicationUri, caller.applicationUri);
      expect(writer.context, isNull);

      reads.clear();
      expect((await client.read(_node)).asInt, 7);
      expect(reads.single.sessionId, caller.sessionId);
      expect(reads.single.identity, isA<AnonymousSessionIdentity>());
    });

    test('Server.write and Server.read run in the admin session', () {
      // Server.write cannot wait for an async write: open62541 cancels the
      // operation and answers Bad_WaitingForResponse, as for a plain onWrite.
      final waiting = throwsA(_status(raw.UA_STATUSCODE_BADWAITINGFORRESPONSE));
      expect(() => server.write(_node, DynamicValue(value: 3, typeId: NodeId.int32)), waiting);
      final (value, writer) = writes.single;
      expect(value, 3);
      expect(writer.isAdminSession, isTrue);
      expect(writer.sessionId, SessionInfo.adminSessionId);
      expect(writer.sessionName, isNull);
      expect(writer.applicationUri, isNull);
      expect(writer.applicationName, isNull);
      expect(writer.identity, isNull);
      expect(writer.context, isNull);

      expect(server.read(_node).asInt, 3);
      expect(reads.single.isAdminSession, isTrue);

      final plain = NodeId.fromString(1, 'ds.session.plain');
      final plainWrites = <int>[];
      server.addDataSourceVariableNode(
        plain,
        browseName: 'ds.session.plain',
        typeId: NodeId.int32,
        onRead: () => DynamicValue(value: 0, typeId: NodeId.int32),
        onWrite: (value) async => plainWrites.add(value.asInt!),
      );
      expect(() => server.write(plain, DynamicValue(value: 4, typeId: NodeId.int32)), waiting);
      expect(plainWrites, [4]);
    });

    test('a monitored item samples in the session that owns the subscription', () async {
      final caller = await callerOf(client);
      final subId = await client.subscriptionCreate(requestedPublishingInterval: const Duration(milliseconds: 50));
      final values = <int>[];
      final sub = client
          .monitor(_node, subId, samplingInterval: const Duration(milliseconds: 50))
          .listen((v) => values.add(v.asInt!));
      addTearDown(sub.cancel);
      reads.clear();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(reads.length, greaterThan(1));
      expect(reads.map((s) => s.sessionId).toSet(), {caller.sessionId});
      expect(values, contains(0));
    });

    test('errors from the session handlers map to statuses like onWrite / onReadValue', () async {
      final node = NodeId.fromString(1, 'ds.session.errors');
      Object? writeError;
      Object? readError;
      server.addDataSourceVariableNode(
        node,
        browseName: 'ds.session.errors',
        typeId: NodeId.int32,
        onReadWithSession: (_) {
          final error = readError;
          if (error != null) throw error;
          return DataSourceValue(value: DynamicValue(value: 1, typeId: NodeId.int32));
        },
        onWriteWithSession: (_, _) async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          throw writeError!;
        },
      );
      final value = DynamicValue(value: 2, typeId: NodeId.int32);
      writeError = const UaStatusException(raw.UA_STATUSCODE_BADNOTWRITABLE);
      await expectLater(client.write(node, value), throwsA(_status(raw.UA_STATUSCODE_BADNOTWRITABLE)));
      writeError = StateError('device gone');
      await expectLater(client.write(node, value), throwsA(_status(raw.UA_STATUSCODE_BADINTERNALERROR)));

      readError = const UaStatusException(raw.UA_STATUSCODE_BADNOCOMMUNICATION);
      expect(
        statusCodeToString((await client.readValue(node)).statusCode),
        statusCodeToString(raw.UA_STATUSCODE_BADNOCOMMUNICATION),
      );
      readError = StateError('read failed');
      expect(
        statusCodeToString((await client.readValue(node)).statusCode),
        statusCodeToString(raw.UA_STATUSCODE_BADINTERNALERROR),
      );
    });

    test('a ClientIsolate write and read reach the session handlers', () async {
      final isolate = await setupClientOfType('isolate', 'opc.tcp://127.0.0.1:${server.port}');
      addTearDown(isolate.delete);
      final caller = await callerOf(isolate);
      await isolate.write(_node, DynamicValue(value: 11, typeId: NodeId.int32));
      expect(writes.single.$1, 11);
      expect(writes.single.$2.sessionId, caller.sessionId);
      reads.clear();
      expect((await isolate.read(_node)).asInt, 11);
      expect(reads.single.sessionId, caller.sessionId);
    });

    test('setVariableValueSource takes the session handlers too', () async {
      final caller = await callerOf(client);
      final node = NodeId.fromString(1, 'ds.session.existing');
      server.addVariableNode(node, DynamicValue(value: 0, typeId: NodeId.int32, name: 'existing'));
      final seen = <SessionInfo>[];
      server.setVariableValueSource(
        node,
        onReadWithSession: (session) {
          seen.add(session);
          return DataSourceValue(value: DynamicValue(value: 5, typeId: NodeId.int32));
        },
        onWriteWithSession: (_, session) async => seen.add(session),
      );
      expect((await client.read(node)).asInt, 5);
      await client.write(node, DynamicValue(value: 6, typeId: NodeId.int32));
      expect(seen.map((s) => s.sessionId), [caller.sessionId, caller.sessionId]);
    });

    test('a plain and a session variant of one handler kind are refused', () {
      DynamicValue read() => DynamicValue(value: 0, typeId: NodeId.int32);
      DataSourceValue readValue() => DataSourceValue(value: read());
      DataSourceValue readWithSession(SessionInfo _) => readValue();
      Future<void> write(DynamicValue _) async {}
      Future<void> writeWithSession(DynamicValue _, SessionInfo _) async {}
      final node = NodeId.fromString(1, 'ds.session.refused');

      expect(
        () => server.addDataSourceVariableNode(
          node,
          browseName: 'refused',
          onRead: read,
          onWrite: write,
          onWriteWithSession: writeWithSession,
        ),
        throwsArgumentError,
      );
      expect(
        () => server.addDataSourceVariableNode(
          node,
          browseName: 'refused',
          onReadValue: readValue,
          onReadWithSession: readWithSession,
        ),
        throwsArgumentError,
      );
      expect(
        () => server.addDataSourceVariableNode(
          node,
          browseName: 'refused',
          onRead: read,
          onReadWithSession: readWithSession,
        ),
        throwsArgumentError,
      );
      expect(
        () => server.setVariableValueSource(_node, onRead: read, onWrite: write, onWriteWithSession: writeWithSession),
        throwsArgumentError,
      );
      expect(
        () => server.setVariableValueSource(_node, onReadValue: readValue, onReadWithSession: readWithSession),
        throwsArgumentError,
      );
    });
  });

  group('with ServerSecurity and AccessControl', () {
    late CertificateAndKey serverIdentity;
    late CertificateAndKey clientIdentity;
    late _LoginAccessControl ac;
    late SecuredServer server;
    final reads = <SessionInfo>[];
    final writes = <SessionInfo>[];

    setUpAll(() {
      serverIdentity = createSelfSignedCertificate(applicationUri: securedServerUri, subject: ['CN=ds server']);
      clientIdentity = createSelfSignedCertificate(applicationUri: _clientUri, subject: ['CN=ds client']);
    });

    setUp(() {
      reads.clear();
      writes.clear();
      ac = _LoginAccessControl();
      server = SecuredServer(
        ServerSecurity(
          certificate: serverIdentity.certificate,
          privateKey: serverIdentity.privateKey,
          applicationTrust: TrustList(trusted: [clientIdentity.certificate]),
        ),
        accessControl: ac,
      );
      server.server.addDataSourceVariableNode(
        _node,
        browseName: 'ds.session',
        typeId: NodeId.int32,
        onReadWithSession: (session) {
          reads.add(session);
          return DataSourceValue(value: DynamicValue(value: 1, typeId: NodeId.int32));
        },
        onWriteWithSession: (value, session) async => writes.add(session),
      );
    });

    tearDown(() => server.delete());

    Client securedClient({String? username, String? password}) => Client(
      certificate: clientIdentity.certificate.der,
      privateKey: clientIdentity.privateKey,
      applicationUri: _clientUri,
      serverTrust: TrustList(trusted: [serverIdentity.certificate]),
      securityMode: signAndEncrypt,
      username: username,
      password: password,
      logLevel: LogLevel.UA_LOGLEVEL_FATAL,
    );

    test('a user name session hands the handlers its activateSession context', () async {
      final client = securedClient(username: 'operator', password: 'secret');
      addTearDown(() => deleteClient(client));
      expect(await connectStatus(client, server.url), raw.UA_STATUSCODE_GOOD);

      await pumped(client, client.write(_node, DynamicValue(value: 2, typeId: NodeId.int32)));
      final writer = writes.single;
      expect(writer.context, same(ac.contexts.single));
      expect(writer.identity, isA<UsernameSessionIdentity>().having((i) => i.username, 'username', 'operator'));
      expect(writer.applicationUri, _clientUri);
      expect(writer.isAdminSession, isFalse);

      await pumped(client, client.read(_node));
      expect(reads.single.context, same(ac.contexts.single));
      expect(reads.single.sessionId, writer.sessionId);
    });

    test('an anonymous session and the admin session', () async {
      final client = securedClient();
      addTearDown(() => deleteClient(client));
      expect(await connectStatus(client, server.url), raw.UA_STATUSCODE_GOOD);

      await pumped(client, client.write(_node, DynamicValue(value: 2, typeId: NodeId.int32)));
      expect(writes.single.context, 'anonymous');
      expect(writes.single.identity, isA<AnonymousSessionIdentity>());

      expect(
        () => server.server.write(_node, DynamicValue(value: 3, typeId: NodeId.int32)),
        throwsA(_status(raw.UA_STATUSCODE_BADWAITINGFORRESPONSE)),
      );
      expect(writes.last.isAdminSession, isTrue);
      expect(writes.last.context, isNull);
      expect(writes.last.identity, isNull);
    });
  });
}
