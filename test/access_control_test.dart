import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/common.dart';
import 'package:open62541/src/extensions.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'package:open62541/src/ua_allocation.dart';
import 'common.dart';
import 'security_harness.dart';

const _clientUri = 'urn:open62541.dart.test.ac.client';
const _readOnly = 1;
const _unreadable = 2;
const _hidden = 3;
const _notCallable = 4;
final _plain = NodeId.fromString(1, 'ac.plain');
final _readOnlyNode = NodeId.fromString(1, 'ac.readonly');
final _unreadableNode = NodeId.fromString(1, 'ac.unreadable');
final _hiddenNode = NodeId.fromString(1, 'ac.hidden');
final _folder = NodeId.fromString(1, 'ac.folder');
final _callable = NodeId.fromString(1, 'ac.callable');
final _notCallableMethod = NodeId.fromString(1, 'ac.notcallable');

/// Logs in `operator`/`secret` (context `operator`) and anonymous sessions
/// (context `anonymous #n`), and denies by access tag.
class RecordingAccessControl extends AccessControl {
  RecordingAccessControl({this.types = const {UserTokenType.anonymous, UserTokenType.username}});

  final Set<UserTokenType> types;
  final activations = <SessionActivation>[];
  final passwordsSeen = <String>[];
  final closed = <ActiveSession>[];
  var allowNodeManagement = true;
  var throwOnAccessLevel = false;
  var throwOnActivate = false;
  var accessLevelCalls = 0;
  var rightsMaskCalls = 0;

  @override
  Set<UserTokenType> get userTokenTypes => types;

  @override
  Object? activateSession(SessionActivation activation) {
    activations.add(activation);
    if (throwOnActivate) throw StateError('activateSession failed');
    if (activation.tokenType == UserTokenType.username) {
      final password = utf8.decode(activation.password!);
      passwordsSeen.add(password);
      if (activation.username != 'operator' || password != 'secret') {
        throw const UaStatusException(raw.UA_STATUSCODE_BADUSERACCESSDENIED);
      }
      return 'operator';
    }
    return 'anonymous #${activations.length}';
  }

  @override
  void closeSession(ActiveSession session) => closed.add(session);

  @override
  int userAccessLevel(Object? context, NodeRef node) {
    accessLevelCalls++;
    if (throwOnAccessLevel) throw StateError('userAccessLevel failed');
    return switch (node.tag) {
      _readOnly => raw.UA_ACCESSLEVELMASK_READ,
      _unreadable => 0,
      _ => 0xFF,
    };
  }

  @override
  int userRightsMask(Object? context, NodeRef node) {
    rightsMaskCalls++;
    return 0xFFFFFFFF;
  }

  @override
  bool allowBrowse(Object? context, NodeRef node) => node.tag != _hidden;

  @override
  bool userExecutableOnObject(Object? context, NodeRef method, NodeRef object) => method.tag != _notCallable;

  @override
  bool userExecutable(Object? context, NodeRef method) => method.tag != _notCallable;

  @override
  bool allowAddNode(Object? context, NodeRef parent) => allowNodeManagement;

  @override
  bool allowAddReference(Object? context, NodeRef source) => allowNodeManagement;

  @override
  bool allowDeleteNode(Object? context, NodeRef node) => allowNodeManagement;

  @override
  bool allowDeleteReference(Object? context, NodeRef source) => allowNodeManagement;
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

Future<void> waitFor(bool Function() condition, {String reason = 'condition'}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $reason');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late CertificateAndKey serverIdentity;
  late CertificateAndKey clientIdentity;

  setUpAll(() {
    serverIdentity = createSelfSignedCertificate(applicationUri: securedServerUri, subject: ['CN=ac server']);
    clientIdentity = createSelfSignedCertificate(applicationUri: _clientUri, subject: ['CN=ac client']);
  });

  ServerSecurity security({bool allowNone = false, bool allowUnencryptedPassword = false, TrustList? userTrust}) =>
      ServerSecurity(
        certificate: serverIdentity.certificate,
        privateKey: serverIdentity.privateKey,
        applicationTrust: TrustList(trusted: [clientIdentity.certificate]),
        allowNone: allowNone,
        allowUnencryptedPassword: allowUnencryptedPassword,
        userTrust: userTrust,
      );

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

  /// A secured server with [ac] and the nodes the tests decide about.
  SecuredServer acServer(AccessControl ac, {ServerSecurity? withSecurity}) {
    final secured = SecuredServer(withSecurity ?? security(), accessControl: ac);
    final server = secured.server;
    server.addVariableNode(_plain, DynamicValue(value: 1, typeId: NodeId.int32, name: 'plain'));
    server.addVariableNode(
      _readOnlyNode,
      DynamicValue(value: 2, typeId: NodeId.int32, name: 'readonly'),
      accessTag: _readOnly,
    );
    server.addDataSourceVariableNode(
      _unreadableNode,
      browseName: 'unreadable',
      onRead: () => DynamicValue(value: 3, typeId: NodeId.int32),
      accessTag: _unreadable,
    );
    server.addObjectNode(_folder, browseName: 'folder');
    server.addVariableNode(
      _hiddenNode,
      DynamicValue(value: 4, typeId: NodeId.int32, name: 'hidden'),
      parentNodeId: _folder,
      accessTag: _hidden,
    );
    server.addVariableNode(
      NodeId.fromString(1, 'ac.visible'),
      DynamicValue(value: 5, typeId: NodeId.int32, name: 'visible'),
      parentNodeId: _folder,
    );
    return secured;
  }

  group('activation', () {
    test('a user name login is accepted, a wrong password refused', () async {
      final ac = RecordingAccessControl(types: {UserTokenType.username});
      final server = acServer(ac);
      addTearDown(server.delete);

      final good = securedClient(username: 'operator', password: 'secret');
      expect(await connectStatus(good, server.url), raw.UA_STATUSCODE_GOOD);
      final activation = ac.activations.single;
      expect(activation.tokenType, UserTokenType.username);
      expect(activation.username, 'operator');
      expect(ac.passwordsSeen, ['secret']);
      expect(activation.password, everyElement(0), reason: 'zeroed after activateSession returned');
      expect(activation.reactivation, isFalse);
      expect(activation.securityMode, signAndEncrypt);
      expect(activation.securityPolicyUri, SecurityPolicy.aes256Sha256RsaPss.uri);
      expect(activation.clientCertificate, clientIdentity.certificate);
      expect(activation.clientApplicationUri, _clientUri);
      expect(activation.remoteAddress, '127.0.0.1');
      await deleteClient(good);

      final bad = securedClient(username: 'operator', password: 'wrong');
      expect(statusCodeToString(await connectStatus(bad, server.url)), 'BadUserAccessDenied');
      await deleteClient(bad);

      // No anonymous token on offer: the client finds no endpoint to use.
      final anonymous = securedClient();
      expect(statusCodeToString(await connectStatus(anonymous, server.url)), 'BadIdentityTokenRejected');
      await deleteClient(anonymous);
      expect(ac.activations, hasLength(2));
    });

    test('the endpoints offer exactly the token types, once each', () async {
      final server = acServer(RecordingAccessControl(types: {UserTokenType.username, UserTokenType.anonymous}));
      addTearDown(server.delete);
      final endpoints = await Client.getEndpoints(server.url);
      expect(endpoints, hasLength(6));
      for (final endpoint in endpoints) {
        expect(endpoint.userTokenPolicies.map((p) => p.tokenType), [UserTokenType.anonymous, UserTokenType.username]);
      }
    });

    test('a throwing activateSession refuses the session', () async {
      final ac = RecordingAccessControl()..throwOnActivate = true;
      final server = acServer(ac);
      addTearDown(server.delete);
      final client = securedClient();
      expect(statusCodeToString(await connectStatus(client, server.url)), 'BadUserAccessDenied');
      await deleteClient(client);
      expect(ac.closed, isEmpty, reason: 'a refused session never had a context');
    });

    test('re-activation on a new channel sees the previous context', () async {
      final ac = RecordingAccessControl();
      final server = acServer(ac);
      addTearDown(server.delete);
      final proxy = await TcpProxy.start(server.server.port);
      final client = securedClient(username: 'operator', password: 'secret');
      addTearDown(() async {
        client.stopKeepConnected();
        await deleteClient(client);
      });
      await client
          .keepConnected('opc.tcp://127.0.0.1:${proxy.port}', nonBlocking: true, iterateInterval: Duration.zero)
          .timeout(const Duration(seconds: 15));
      expect(ac.activations, hasLength(1));

      proxy.cut();
      await waitForChannelDown(client);
      proxy.resume();
      await waitFor(() => ac.activations.length == 2, reason: 're-activation');

      final again = ac.activations.last;
      expect(again.reactivation, isTrue);
      expect(again.previousContext, 'operator');
      expect(again.sessionId, ac.activations.first.sessionId);
      expect(ac.closed, isEmpty);
    });
  });

  group('node hooks', () {
    late RecordingAccessControl ac;
    late SecuredServer server;
    late Client client;

    setUp(() async {
      ac = RecordingAccessControl();
      server = acServer(ac);
      client = securedClient(username: 'operator', password: 'secret');
      expect(await connectStatus(client, server.url), raw.UA_STATUSCODE_GOOD);
    });

    tearDown(() async {
      await deleteClient(client);
      server.delete();
    });

    test('userAccessLevel strips write and read', () async {
      await pumped(client, client.write(_plain, DynamicValue(value: 10, typeId: NodeId.int32)));
      expect((await pumped(client, client.readValue(_readOnlyNode))).value.value, 2);
      await expectLater(
        pumped(client, client.write(_readOnlyNode, DynamicValue(value: 20, typeId: NodeId.int32))),
        throwsA(
          isA<UaStatusException>().having((e) => e.statusCode, 'statusCode', raw.UA_STATUSCODE_BADUSERACCESSDENIED),
        ),
      );
      final denied = await pumped(client, client.readValue(_unreadableNode));
      expect(statusCodeToString(denied.statusCode), 'BadUserAccessDenied');
      // The server's own access is never asked.
      expect(server.server.read(_unreadableNode).value, 3);
    });

    test('setAccessTag retags an existing node', () async {
      server.server.setAccessTag(_plain, _unreadable);
      expect(statusCodeToString((await pumped(client, client.readValue(_plain))).statusCode), 'BadUserAccessDenied');
      server.server.setAccessTag(_plain, 0);
      expect((await pumped(client, client.readValue(_plain))).statusCode, raw.UA_STATUSCODE_GOOD);
      expect(
        () => server.server.setAccessTag(NodeId.fromString(1, 'ac.missing'), 1),
        throwsA(isA<UaStatusException>()),
      );
      expect(() => server.server.setAccessTag(_plain, -1), throwsArgumentError);
    });

    test('a throwing userAccessLevel denies', () async {
      ac.throwOnAccessLevel = true;
      expect(statusCodeToString((await pumped(client, client.readValue(_plain))).statusCode), 'BadUserAccessDenied');
    });

    test('allowBrowse refuses browsing the node, not the references to it', () async {
      await expectLater(
        pumped(client, client.browse(_hiddenNode)),
        throwsA(predicate((e) => e.toString().contains('BadUserAccessDenied'))),
      );
      final children = await pumped(client, client.browse(_folder));
      expect(children.map((c) => c.browseName), containsAll(['visible', 'hidden']));
    });

    test('userExecutableOnObject refuses a call; MethodSessionInfo carries the context', () async {
      final sessions = <MethodSessionInfo>[];
      Future<List<DynamicValue>> handler(List<DynamicValue> inputs, MethodSessionInfo session) async {
        sessions.add(session);
        return [];
      }

      server.server.addMethodNode(_callable, callback: handler);
      server.server.addMethodNode(_notCallableMethod, callback: handler, accessTag: _notCallable);
      final objects = NodeId.fromNumeric(0, raw.UA_NS0ID_OBJECTSFOLDER);
      await pumped(client, client.call(objects, _callable, []));
      expect(sessions.single.context, 'operator');
      expect(
        sessions.single.identity,
        isA<UsernameSessionIdentity>().having((i) => i.username, 'username', 'operator'),
      );
      expect(sessions.single.sessionId, ac.activations.single.sessionId);
      expect(sessions.single.applicationUri, _clientUri);
      await expectLater(
        pumped(client, client.call(objects, _notCallableMethod, [])),
        throwsA(predicate((e) => e.toString().contains('BadUserAccessDenied'))),
      );
      expect(sessions, hasLength(1));
    });

    test('closeSession runs on disconnect and for Server.closeSession', () async {
      final sessionId = ac.activations.single.sessionId;
      // A client on another isolate, so its CloseSession is answered.
      final other = await ClientIsolate.create(
        certificate: clientIdentity.certificate.der,
        privateKey: clientIdentity.privateKey,
        applicationUri: _clientUri,
        serverTrust: TrustList(trusted: [serverIdentity.certificate]),
        securityMode: signAndEncrypt,
        username: 'operator',
        password: 'secret',
      );
      addTearDown(other.delete);
      await other.connect(server.url, timeout: const Duration(seconds: 10));
      final otherId = ac.activations.last.sessionId;
      await other.disconnect();
      await waitFor(() => ac.closed.isNotEmpty, reason: 'closeSession');
      expect(ac.closed.single.sessionId, otherId);
      expect(ac.closed.single.context, 'operator');

      server.server.closeSession(sessionId);
      expect(ac.closed.map((s) => s.sessionId), [otherId, sessionId]);
      expect(() => server.server.closeSession(sessionId), throwsA(isA<UaStatusException>()));
    });

    test('a micro-benchmark of userAccessLevel calls per read (not gating)', () async {
      const reads = 200;
      final before = ac.accessLevelCalls;
      final watch = Stopwatch()..start();
      for (var i = 0; i < reads; i++) {
        await pumped(client, client.readValue(_plain));
      }
      watch.stop();
      final calls = ac.accessLevelCalls - before;
      expect(calls, greaterThanOrEqualTo(reads));
      printOnFailure('$reads reads: $calls userAccessLevel calls, ${watch.elapsedMicroseconds ~/ reads} us/read');
      // ignore: avoid_print
      print(
        'access control: $reads reads, $calls userAccessLevel calls, ${watch.elapsedMicroseconds ~/ reads} us/read',
      );
    });
  });

  test('closeSession runs for open sessions when the server is deleted', () async {
    final ac = RecordingAccessControl();
    final server = acServer(ac);
    final client = securedClient(username: 'operator', password: 'secret');
    expect(await connectStatus(client, server.url), raw.UA_STATUSCODE_GOOD);
    expect(ac.closed, isEmpty);
    server.delete();
    expect(ac.closed.single.context, 'operator');
    await deleteClient(client);
  });

  group('node management', () {
    test('AddNodes, AddReferences, DeleteNodes and DeleteReferences ask the access control', () async {
      final ac = RecordingAccessControl(types: {UserTokenType.anonymous});
      final server = acServer(ac, withSecurity: security(allowNone: true));
      addTearDown(server.delete);
      final session = await RawSession.open(server.url);
      addTearDown(session.close);

      ac.allowNodeManagement = false;
      for (final service in NodeManagement.values) {
        expect(statusCodeToString(await session.manage(service, _plain)), 'BadUserAccessDenied', reason: service.name);
      }
      ac.allowNodeManagement = true;
      for (final service in NodeManagement.values) {
        expect(
          statusCodeToString(await session.manage(service, _plain)),
          isNot('BadUserAccessDenied'),
          reason: service.name,
        );
      }
      expect(await session.manage(NodeManagement.deleteNodes, _hiddenNode), raw.UA_STATUSCODE_GOOD);
    });

    test('UserExecutable and UserWriteMask reads ask userExecutable and userRightsMask', () async {
      final ac = RecordingAccessControl(types: {UserTokenType.anonymous});
      final server = acServer(ac, withSecurity: security(allowNone: true));
      addTearDown(server.delete);
      Future<List<DynamicValue>> handler(List<DynamicValue> inputs, MethodSessionInfo session) async => [];
      server.server.addMethodNode(_callable, callback: handler);
      server.server.addMethodNode(_notCallableMethod, callback: handler, accessTag: _notCallable);
      final session = await RawSession.open(server.url);
      addTearDown(session.close);

      expect(await session.readBoolean(_callable, AttributeId.UA_ATTRIBUTEID_USEREXECUTABLE.value), isTrue);
      expect(await session.readBoolean(_notCallableMethod, AttributeId.UA_ATTRIBUTEID_USEREXECUTABLE.value), isFalse);
      await session.readBoolean(_plain, AttributeId.UA_ATTRIBUTEID_USERWRITEMASK.value);
      expect(ac.rightsMaskCalls, 1);
    });
  });

  group('DefaultAccessControl', () {
    test('mirrors UA_AccessControl_default', () async {
      final server = acServer(DefaultAccessControl(allowAnonymous: false, users: {'operator': 'secret'}));
      addTearDown(server.delete);
      final good = securedClient(username: 'operator', password: 'secret');
      expect(await connectStatus(good, server.url), raw.UA_STATUSCODE_GOOD);
      await deleteClient(good);
      final wrong = securedClient(username: 'operator', password: 'secre');
      expect(statusCodeToString(await connectStatus(wrong, server.url)), 'BadUserAccessDenied');
      await deleteClient(wrong);
      final unknown = securedClient(username: 'intruder', password: 'secret');
      expect(statusCodeToString(await connectStatus(unknown, server.url)), 'BadUserAccessDenied');
      await deleteClient(unknown);
      final anonymous = securedClient();
      expect(statusCodeToString(await connectStatus(anonymous, server.url)), 'BadIdentityTokenRejected');
      await deleteClient(anonymous);
    });

    test('refuses tokens it does not offer, also when a client sends one anyway', () {
      final ac = DefaultAccessControl(allowAnonymous: false);
      expect(ac.userTokenTypes, isEmpty);
      SessionActivation activation(UserTokenType type, {String? username, List<int>? password}) => SessionActivation(
        sessionId: NodeId.fromNumeric(1, 1),
        tokenType: type,
        username: username,
        password: password == null ? null : Uint8List.fromList(password),
        securityMode: signAndEncrypt,
        securityPolicyUri: SecurityPolicy.basic256Sha256.uri,
      );
      final isInvalid = throwsA(
        isA<UaStatusException>().having((e) => e.statusCode, 'statusCode', raw.UA_STATUSCODE_BADIDENTITYTOKENINVALID),
      );
      expect(() => ac.activateSession(activation(UserTokenType.anonymous)), isInvalid);
      expect(() => ac.activateSession(activation(UserTokenType.certificate)), isInvalid);
      expect(() => ac.activateSession(activation(UserTokenType.username, username: '', password: [])), isInvalid);
      expect(
        () => ac.activateSession(activation(UserTokenType.username, username: 'x', password: [1])),
        throwsA(isA<UaStatusException>()),
      );
      final users = DefaultAccessControl(users: {'a': 'b'}, allowCertificate: true);
      expect(users.userTokenTypes, {UserTokenType.anonymous, UserTokenType.username, UserTokenType.certificate});
      expect(users.activateSession(activation(UserTokenType.username, username: 'a', password: utf8.encode('b'))), 'a');
      expect(users.activateSession(activation(UserTokenType.anonymous)), isNull);
    });

    test('a user name over None with allowUnencryptedPassword', () async {
      final server = acServer(
        DefaultAccessControl(allowAnonymous: false, users: {'operator': 'secret'}),
        withSecurity: security(allowNone: true, allowUnencryptedPassword: true),
      );
      addTearDown(server.delete);
      final client = Client(
        username: 'operator',
        password: 'secret',
        allowUnencryptedPassword: true,
        logLevel: LogLevel.UA_LOGLEVEL_FATAL,
      );
      addTearDown(() => deleteClient(client));
      expect(await connectStatus(client, server.url), raw.UA_STATUSCODE_GOOD);
    });
  });

  test('allowTransferSubscription defaults to open62541\'s rule', () {
    final ac = DefaultAccessControl();
    ActiveSession session(UserTokenType type, {String? username, String policy = '', String? appUri}) => ActiveSession(
      NodeId.fromNumeric(1, 1),
      null,
      SessionActivation(
        sessionId: NodeId.fromNumeric(1, 1),
        tokenType: type,
        username: username,
        securityMode: signAndEncrypt,
        securityPolicyUri: policy.isEmpty ? SecurityPolicy.basic256Sha256.uri : policy,
        clientApplicationUri: appUri,
      ),
    );
    final operator = session(UserTokenType.username, username: 'operator');
    expect(ac.allowTransferSubscription(null, operator), isFalse);
    expect(ac.allowTransferSubscription(operator, session(UserTokenType.username, username: 'operator')), isTrue);
    expect(ac.allowTransferSubscription(operator, session(UserTokenType.username, username: 'other')), isFalse);
    expect(ac.allowTransferSubscription(operator, session(UserTokenType.anonymous)), isFalse);
    final anonymous = session(UserTokenType.anonymous, appUri: 'urn:a');
    expect(ac.allowTransferSubscription(anonymous, session(UserTokenType.anonymous, appUri: 'urn:a')), isTrue);
    expect(ac.allowTransferSubscription(anonymous, session(UserTokenType.anonymous, appUri: 'urn:b')), isFalse);
    expect(
      ac.allowTransferSubscription(
        anonymous,
        session(UserTokenType.anonymous, appUri: 'urn:a', policy: SecurityPolicy.none.uri),
      ),
      isFalse,
    );
  });

  test('token types the server cannot verify are refused at construction', () {
    expect(
      () => Server(port: 0, accessControl: DefaultAccessControl(users: {'a': 'b'})),
      throwsA(isA<ArgumentError>().having((e) => e.toString(), 'message', contains('ServerSecurity'))),
    );
    expect(
      () => Server(
        port: 0,
        applicationUri: securedServerUri,
        security: security(),
        accessControl: DefaultAccessControl(allowCertificate: true),
      ),
      throwsA(isA<ArgumentError>().having((e) => e.toString(), 'message', contains('userTrust'))),
    );
    expect(() => Server(port: 0, accessControl: DefaultAccessControl(allowAnonymous: false)), throwsArgumentError);
    final server = Server(
      port: 0,
      applicationUri: securedServerUri,
      security: security(userTrust: const TrustList()),
      accessControl: DefaultAccessControl(allowCertificate: true),
    );
    server.delete();
  });

  test('an anonymous-only access control works without ServerSecurity', () async {
    final ac = RecordingAccessControl(types: {UserTokenType.anonymous});
    final server = Server(port: 0, logLevel: LogLevel.UA_LOGLEVEL_FATAL, accessControl: ac);
    server.start();
    final pump = Timer.periodic(const Duration(milliseconds: 2), (_) => server.runIterate());
    addTearDown(() {
      pump.cancel();
      server.shutdown();
      server.delete();
    });
    final client = Client(logLevel: LogLevel.UA_LOGLEVEL_FATAL);
    addTearDown(() => deleteClient(client));
    expect(await connectStatus(client, 'opc.tcp://127.0.0.1:${server.port}'), raw.UA_STATUSCODE_GOOD);
    expect(ac.activations.single.tokenType, UserTokenType.anonymous);
    expect(ac.activations.single.clientCertificate, isNull);
    expect(ac.activations.single.securityPolicyUri, SecurityPolicy.none.uri);
  });
}

/// The node management services, sent with one item whose first NodeId
/// (parent, node or source) is the node under test.
enum NodeManagement {
  addNodes(raw.UA_TYPES_ADDNODESREQUEST, raw.UA_TYPES_ADDNODESRESPONSE, raw.UA_TYPES_ADDNODESITEM, 'NodesToAdd'),
  addReferences(
    raw.UA_TYPES_ADDREFERENCESREQUEST,
    raw.UA_TYPES_ADDREFERENCESRESPONSE,
    raw.UA_TYPES_ADDREFERENCESITEM,
    'ReferencesToAdd',
  ),
  deleteNodes(
    raw.UA_TYPES_DELETENODESREQUEST,
    raw.UA_TYPES_DELETENODESRESPONSE,
    raw.UA_TYPES_DELETENODESITEM,
    'NodesToDelete',
  ),
  deleteReferences(
    raw.UA_TYPES_DELETEREFERENCESREQUEST,
    raw.UA_TYPES_DELETEREFERENCESRESPONSE,
    raw.UA_TYPES_DELETEREFERENCESITEM,
    'ReferencesToDelete',
  );

  const NodeManagement(this.request, this.response, this.item, this.itemsMember);
  final int request;
  final int response;
  final int item;
  final String itemsMember;
}

/// Offset of each member of a native type, by `UA_DataTypeMember` padding.
Map<String, int> memberOffsets(int typeIndex) {
  final type = getTypeByIndex(typeIndex).ref;
  final offsets = <String, int>{};
  var offset = 0;
  for (var i = 0; i < type.membersSize; i++) {
    final member = type.members[i];
    offset += member.padding;
    offsets[member.memberName.cast<Utf8>().toDartString()] = offset;
    offset += member.isArray
        ? ffi.sizeOf<ffi.Size>() + ffi.sizeOf<ffi.Pointer>()
        : member.isOptional
        ? ffi.sizeOf<ffi.Pointer>()
        : member.memberType.ref.memSize;
  }
  return offsets;
}

/// An anonymous session of a raw open62541 client, for the services the
/// `Client` class does not offer.
class RawSession {
  RawSession._(this._client);

  final ffi.Pointer<raw.UA_Client> _client;

  static Future<RawSession> open(String url) async {
    final config = ua_calloc<raw.UA_ClientConfig>();
    config.ref.logging = raw.UA_Log_Stdout_new(LogLevel.UA_LOGLEVEL_FATAL);
    raw.UA_ClientConfig_setDefault(config);
    final client = raw.UA_Client_newWithConfig(config);
    ua_calloc.free(config);
    final session = RawSession._(client);
    using((arena) => raw.UA_Client_connectAsync(client, url.toNativeUtf8(allocator: arena).cast()), ua_calloc);
    await waitFor(() {
      raw.UA_Client_run_iterate(client, 0);
      return using((arena) {
        final channel = arena<ffi.UnsignedInt>();
        final state = arena<ffi.UnsignedInt>();
        final status = arena<ffi.Uint32>();
        raw.UA_Client_getState(client, channel, state, status);
        return state.value == raw.UA_SessionState.UA_SESSIONSTATE_ACTIVATED.value;
      }, ua_calloc);
    }, reason: 'raw session');
    return session;
  }

  /// Sends [service] for [node] and answers the operation's status.
  Future<int> manage(NodeManagement service, NodeId node) async {
    final requestType = getTypeByIndex(service.request);
    final itemType = getTypeByIndex(service.item);
    final request = ua_calloc<ffi.Uint8>(requestType.ref.memSize);
    final item = ua_calloc<ffi.Uint8>(itemType.ref.memSize);
    item.cast<raw.UA_NodeId>().ref = node.toRaw();
    if (service == NodeManagement.addNodes) {
      final browseName = (item + memberOffsets(service.item)['BrowseName']!).cast<raw.UA_QualifiedName>();
      browseName.ref.namespaceIndex = 1;
      browseName.ref.name.set('added');
    }
    final itemsOffset = memberOffsets(service.request)[service.itemsMember]!;
    (request + itemsOffset).cast<ffi.Size>().value = 1;
    (request + itemsOffset + ffi.sizeOf<ffi.Size>()).cast<ffi.Pointer<ffi.Uint8>>().value = item;

    final result = Completer<int>();
    final responseResults = memberOffsets(service.response)['Results']!;
    final serviceResult = memberOffsets(raw.UA_TYPES_RESPONSEHEADER)['ServiceResult']!;
    final callback =
        ffi.NativeCallable<
          ffi.Void Function(ffi.Pointer<raw.UA_Client>, ffi.Pointer<ffi.Void>, ffi.Uint32, ffi.Pointer<ffi.Void>)
        >.isolateLocal((ffi.Pointer<raw.UA_Client> c, ffi.Pointer<ffi.Void> userdata, int id, ffi.Pointer<ffi.Void> r) {
          final response = r.cast<ffi.Uint8>();
          final status = (response + serviceResult).cast<ffi.Uint32>().value;
          if (status != raw.UA_STATUSCODE_GOOD) {
            result.complete(status);
            return;
          }
          // Every result type starts with its StatusCode.
          final results = (response + responseResults + ffi.sizeOf<ffi.Size>()).cast<ffi.Pointer<ffi.Uint32>>().value;
          result.complete(results.value);
        });
    final sent = raw.UA_Client_AsyncService(
      _client,
      request.cast(),
      requestType,
      callback.nativeFunction,
      getTypeByIndex(service.response),
      ffi.nullptr,
      ffi.nullptr,
    );
    raw.UA_clear(request.cast(), requestType);
    ua_calloc.free(request);
    try {
      if (sent != raw.UA_STATUSCODE_GOOD) return sent;
      while (!result.isCompleted) {
        raw.UA_Client_run_iterate(_client, 0);
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      return await result.future;
    } finally {
      callback.close();
    }
  }

  /// Reads attribute [attributeId] of [node]; a Boolean comes back as is,
  /// anything else as `null`.
  Future<bool?> readBoolean(NodeId node, int attributeId) async {
    final request = raw.UA_ReadRequest_new();
    request.ref.nodesToRead = ua_calloc<raw.UA_ReadValueId>();
    request.ref.nodesToReadSize = 1;
    request.ref.nodesToRead.ref.nodeId = node.toRaw();
    request.ref.nodesToRead.ref.attributeId = attributeId;
    final result = Completer<bool?>();
    final callback =
        ffi.NativeCallable<
          ffi.Void Function(ffi.Pointer<raw.UA_Client>, ffi.Pointer<ffi.Void>, ffi.Uint32, ffi.Pointer<ffi.Void>)
        >.isolateLocal((ffi.Pointer<raw.UA_Client> c, ffi.Pointer<ffi.Void> userdata, int id, ffi.Pointer<ffi.Void> r) {
          final response = r.cast<raw.UA_ReadResponse>().ref;
          final value = response.resultsSize == 1 ? response.results.ref.value : null;
          result.complete(
            value != null && value.type == getTypeByIndex(raw.UA_TYPES_BOOLEAN)
                ? value.data.cast<ffi.Bool>().value
                : null,
          );
        });
    final readType = getTypeByIndex(raw.UA_TYPES_READREQUEST);
    final sent = raw.UA_Client_AsyncService(
      _client,
      request.cast(),
      readType,
      callback.nativeFunction,
      getTypeByIndex(raw.UA_TYPES_READRESPONSE),
      ffi.nullptr,
      ffi.nullptr,
    );
    raw.UA_ReadRequest_delete(request);
    try {
      expect(sent, raw.UA_STATUSCODE_GOOD);
      while (!result.isCompleted) {
        raw.UA_Client_run_iterate(_client, 0);
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      return await result.future;
    } finally {
      callback.close();
    }
  }

  void close() {
    raw.UA_Client_disconnect(_client);
    raw.UA_Client_delete(_client);
  }
}
