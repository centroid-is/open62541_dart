// The Server's security: encryption with client-certificate verification
// (`certificate`, `trustList`, `acceptAllClientCertificates`, `allowNone`),
// authentication (`allowAnonymous`, `users`, `allowUnencryptedPassword`),
// the node-management refusal for clients (`allowClientNodeManagement`), the
// listen address (`hostname`) and the limits (`ServerLimits`). The
// certificates come from `UA_CreateCertificate` through
// client_trust_list_test.dart's helpers.

import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/common.dart' show getTypeByIndex;
import 'package:open62541/src/extensions.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'package:open62541/src/ua_allocation.dart';
import 'client_trust_list_test.dart' show Identity, createIdentity, refusedWith;
import 'common.dart';
import 'heap_growth.dart';

const _fatal = LogLevel.UA_LOGLEVEL_FATAL;

/// A started [Server] on an OS-picked port, pumped on this isolate until
/// [stop].
class Running {
  Running(this.server) {
    server.start();
    () async {
      while (_running) {
        server.runIterate();
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      _stopped.complete();
    }();
  }

  final Server server;
  bool _running = true;
  final Completer<void> _stopped = Completer<void>();

  String get url => 'opc.tcp://127.0.0.1:${server.port}';

  Future<void> stop() async {
    _running = false;
    await _stopped.future;
    server.shutdown();
    server.delete();
  }
}

/// A client of [clientType], pumped, not yet connected, deleted at the end
/// of the test. With an [identity] it offers SignAndEncrypt and accepts any
/// server certificate (the server side is what is under test here).
Future<ClientApi> clientOf(
  String clientType, {
  Identity? identity,
  String? username,
  String? password,
  bool allowUnencryptedPassword = false,
}) async {
  final securityMode = identity == null ? null : MessageSecurityMode.UA_MESSAGESECURITYMODE_SIGNANDENCRYPT;
  final ClientApi client;
  switch (clientType) {
    case 'isolate':
      final isolate = await ClientIsolate.create(
        securityMode: securityMode,
        certificate: identity?.certificate,
        privateKey: identity?.privateKey,
        acceptAllCertificates: identity != null,
        username: username,
        password: password,
        allowUnencryptedPassword: allowUnencryptedPassword,
        logLevel: _fatal,
      );
      // runIterate fails once the client is deleted (expected in tearDown).
      unawaited(isolate.runIterate().catchError((_) {}));
      client = isolate;
    case 'direct':
      final direct = Client(
        securityMode: securityMode,
        certificate: identity?.certificate,
        privateKey: identity?.privateKey,
        acceptAllCertificates: identity != null,
        username: username,
        password: password,
        allowUnencryptedPassword: allowUnencryptedPassword,
        logLevel: _fatal,
      );
      () async {
        while (direct.runIterate(const Duration(milliseconds: 10))) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }();
      client = direct;
    default:
      throw ArgumentError('Unknown client type: $clientType');
  }
  addTearDown(client.delete);
  return client;
}

/// A bare open62541 client (SecurityPolicy#None, anonymous) that sends the
/// node-management services the Dart clients have no API for.
class RawClient {
  RawClient._(this._client);

  final ffi.Pointer<raw.UA_Client> _client;

  static Future<RawClient> connect(String url) async {
    final config = ua_calloc<raw.UA_ClientConfig>();
    config.ref.logging = raw.UA_Log_Stdout_new(_fatal);
    raw.UA_ClientConfig_setDefault(config);
    final client = RawClient._(raw.UA_Client_newWithConfig(config));
    ua_calloc.free(config);
    addTearDown(() => raw.UA_Client_delete(client._client));
    final status = using(
      (arena) => raw.UA_Client_connectAsync(client._client, url.toNativeUtf8(allocator: arena).cast()),
      ua_calloc,
    );
    expect(status, raw.UA_STATUSCODE_GOOD, reason: 'UA_Client_connectAsync: ${statusCodeToString(status)}');
    await client._until(() => client._sessionState == raw.UA_SessionState.UA_SESSIONSTATE_ACTIVATED.value);
    return client;
  }

  int get _sessionState => using((arena) {
    final channel = arena<ffi.UnsignedInt>();
    final session = arena<ffi.UnsignedInt>();
    final status = arena<raw.UA_StatusCode>();
    raw.UA_Client_getState(_client, channel, session, status);
    return session.value;
  }, ua_calloc);

  Future<void> _until(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail('RawClient: timed out');
      raw.UA_Client_run_iterate(_client, 10);
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  /// Sends [request] and returns what [extract] reads from the response
  /// (inside the callback: open62541 frees the response right after it).
  Future<List<int>> _service(
    ffi.Pointer<ffi.Void> request,
    int requestType,
    int responseType,
    List<int> Function(ffi.Pointer<ffi.Void> response) extract,
  ) async {
    final completer = Completer<List<int>>();
    final callback =
        ffi.NativeCallable<
          ffi.Void Function(ffi.Pointer<raw.UA_Client>, ffi.Pointer<ffi.Void>, raw.UA_UInt32, ffi.Pointer<ffi.Void>)
        >.isolateLocal((
          ffi.Pointer<raw.UA_Client> client,
          ffi.Pointer<ffi.Void> userdata,
          int requestId,
          ffi.Pointer<ffi.Void> response,
        ) {
          completer.complete(extract(response));
        });
    // The request is encoded inside the call, so its memory is scratch.
    final status = raw.UA_Client_AsyncService(
      _client,
      request,
      getTypeByIndex(requestType),
      callback.nativeFunction,
      getTypeByIndex(responseType),
      ffi.nullptr,
      ffi.nullptr,
    );
    expect(status, raw.UA_STATUSCODE_GOOD, reason: 'UA_Client_AsyncService: ${statusCodeToString(status)}');
    await _until(() => completer.isCompleted);
    callback.close();
    return completer.future;
  }

  /// The statuses of a response with a `UA_StatusCode results[]` array, or
  /// the service result alone when the service as a whole failed.
  static List<int> _statusResults(ffi.Pointer<ffi.Void> response) {
    // Every response starts with the ResponseHeader; the status-array
    // responses (DeleteNodes, AddReferences, DeleteReferences) share one
    // layout, read here through UA_DeleteNodesResponse.
    final r = response.cast<raw.UA_DeleteNodesResponse>().ref;
    if (r.responseHeader.serviceResult != raw.UA_STATUSCODE_GOOD) return [r.responseHeader.serviceResult];
    return [for (var i = 0; i < r.resultsSize; i++) r.results[i]];
  }

  /// AddNodes: one object node [newId] under the Objects folder.
  Future<int> addObject(NodeId newId, String browseName) => using((arena) async {
    final item = arena<raw.UA_AddNodesItem>();
    item.ref.parentNodeId.nodeId = NodeId.fromNumeric(0, raw.UA_NS0ID_OBJECTSFOLDER).toRaw();
    item.ref.referenceTypeId = NodeId.fromNumeric(0, raw.UA_NS0ID_ORGANIZES).toRaw();
    item.ref.requestedNewNodeId.nodeId = newId.toRaw();
    item.ref.browseName.namespaceIndex = newId.namespace;
    item.ref.browseName.name.set(browseName, allocator: arena);
    item.ref.nodeClassAsInt = raw.UA_NodeClass.UA_NODECLASS_OBJECT.value;
    final attributes = arena<raw.UA_ObjectAttributes>();
    final size = ffi.sizeOf<raw.UA_ObjectAttributes>();
    final defaults = ffi.Native.addressOf<raw.UA_ObjectAttributes>(raw.UA_ObjectAttributes_default);
    attributes.cast<ffi.Uint8>().asTypedList(size).setAll(0, defaults.cast<ffi.Uint8>().asTypedList(size));
    item.ref.nodeAttributes.encodingAsInt = raw.UA_ExtensionObjectEncoding.UA_EXTENSIONOBJECT_DECODED_NODELETE.value;
    item.ref.nodeAttributes.content.decoded.type = getTypeByIndex(raw.UA_TYPES_OBJECTATTRIBUTES);
    item.ref.nodeAttributes.content.decoded.data = attributes.cast();
    item.ref.typeDefinition.nodeId = NodeId.fromNumeric(0, raw.UA_NS0ID_BASEOBJECTTYPE).toRaw();
    final request = arena<raw.UA_AddNodesRequest>();
    request.ref.nodesToAdd = item;
    request.ref.nodesToAddSize = 1;
    final results = await _service(request.cast(), raw.UA_TYPES_ADDNODESREQUEST, raw.UA_TYPES_ADDNODESRESPONSE, (
      response,
    ) {
      final r = response.cast<raw.UA_AddNodesResponse>().ref;
      if (r.responseHeader.serviceResult != raw.UA_STATUSCODE_GOOD) return [r.responseHeader.serviceResult];
      return [for (var i = 0; i < r.resultsSize; i++) r.results[i].statusCode];
    });
    return results.single;
  }, ua_calloc);

  /// DeleteNodes: [nodeId].
  Future<int> deleteNode(NodeId nodeId) => using((arena) async {
    final item = arena<raw.UA_DeleteNodesItem>();
    item.ref.nodeId = nodeId.toRaw();
    item.ref.deleteTargetReferences = true;
    final request = arena<raw.UA_DeleteNodesRequest>();
    request.ref.nodesToDelete = item;
    request.ref.nodesToDeleteSize = 1;
    final results = await _service(
      request.cast(),
      raw.UA_TYPES_DELETENODESREQUEST,
      raw.UA_TYPES_DELETENODESRESPONSE,
      _statusResults,
    );
    return results.single;
  }, ua_calloc);

  /// AddReferences: a forward Organizes reference from [source] to [target].
  Future<int> addOrganizes(NodeId source, NodeId target) => using((arena) async {
    final item = arena<raw.UA_AddReferencesItem>();
    item.ref.sourceNodeId = source.toRaw();
    item.ref.referenceTypeId = NodeId.fromNumeric(0, raw.UA_NS0ID_ORGANIZES).toRaw();
    item.ref.isForward = true;
    item.ref.targetNodeId.nodeId = target.toRaw();
    item.ref.targetNodeClassAsInt = raw.UA_NodeClass.UA_NODECLASS_VARIABLE.value;
    final request = arena<raw.UA_AddReferencesRequest>();
    request.ref.referencesToAdd = item;
    request.ref.referencesToAddSize = 1;
    final results = await _service(
      request.cast(),
      raw.UA_TYPES_ADDREFERENCESREQUEST,
      raw.UA_TYPES_ADDREFERENCESRESPONSE,
      _statusResults,
    );
    return results.single;
  }, ua_calloc);

  /// DeleteReferences: the forward Organizes reference from [source] to
  /// [target], both directions.
  Future<int> deleteOrganizes(NodeId source, NodeId target) => using((arena) async {
    final item = arena<raw.UA_DeleteReferencesItem>();
    item.ref.sourceNodeId = source.toRaw();
    item.ref.referenceTypeId = NodeId.fromNumeric(0, raw.UA_NS0ID_ORGANIZES).toRaw();
    item.ref.isForward = true;
    item.ref.targetNodeId.nodeId = target.toRaw();
    item.ref.deleteBidirectional = true;
    final request = arena<raw.UA_DeleteReferencesRequest>();
    request.ref.referencesToDelete = item;
    request.ref.referencesToDeleteSize = 1;
    final results = await _service(
      request.cast(),
      raw.UA_TYPES_DELETEREFERENCESREQUEST,
      raw.UA_TYPES_DELETEREFERENCESRESPONSE,
      _statusResults,
    );
    return results.single;
  }, ua_calloc);
}

/// Expects every field of [actual] to be [expected]'s.
void expectLimits(ServerLimits actual, ServerLimits expected) {
  expect(actual.maxSecureChannels, expected.maxSecureChannels);
  expect(actual.maxSessions, expected.maxSessions);
  expect(actual.maxSubscriptions, expected.maxSubscriptions);
  expect(actual.maxSubscriptionsPerSession, expected.maxSubscriptionsPerSession);
  expect(actual.maxMonitoredItems, expected.maxMonitoredItems);
  expect(actual.maxMonitoredItemsPerSubscription, expected.maxMonitoredItemsPerSubscription);
  expect(actual.maxNodesPerRead, expected.maxNodesPerRead);
  expect(actual.maxNodesPerWrite, expected.maxNodesPerWrite);
  expect(actual.maxNodesPerBrowse, expected.maxNodesPerBrowse);
  expect(actual.maxNodesPerMethodCall, expected.maxNodesPerMethodCall);
  expect(actual.maxMessageSize, expected.maxMessageSize);
  expect(actual.maxChunkCount, expected.maxChunkCount);
}

const _sign = MessageSecurityMode.UA_MESSAGESECURITYMODE_SIGN;
const _signAndEncrypt = MessageSecurityMode.UA_MESSAGESECURITYMODE_SIGNANDENCRYPT;
const _none = MessageSecurityMode.UA_MESSAGESECURITYMODE_NONE;
const _basic256Sha256 = 'http://opcfoundation.org/UA/SecurityPolicy#Basic256Sha256';

void main() {
  late Identity serverIdentity;
  late Identity clientIdentity;
  late Identity strangerIdentity;

  setUpAll(() {
    serverIdentity = createIdentity('test server');
    clientIdentity = createIdentity('test client');
    strangerIdentity = createIdentity('a stranger');
  });

  Server secured({
    List<Uint8List>? trustList,
    bool acceptAllClientCertificates = false,
    bool? allowNone,
    bool allowAnonymous = true,
    Map<String, String>? users,
  }) => Server(
    port: 0,
    logLevel: _fatal,
    certificate: serverIdentity.certificate,
    privateKey: serverIdentity.privateKey,
    trustList: trustList,
    acceptAllClientCertificates: acceptAllClientCertificates,
    allowNone: allowNone,
    allowAnonymous: allowAnonymous,
    users: users,
  );

  group('the arguments are checked together:', () {
    test('a certificate and a private key come together', () {
      expect(() => Server(certificate: serverIdentity.certificate), throwsArgumentError);
      expect(() => Server(privateKey: serverIdentity.privateKey), throwsArgumentError);
    });

    test('the lists, accept-all and allowNone: false need a certificate', () {
      expect(() => Server(trustList: [clientIdentity.certificate]), throwsArgumentError);
      expect(() => Server(issuerList: [clientIdentity.certificate]), throwsArgumentError);
      expect(() => Server(revocationList: []), throwsArgumentError);
      expect(() => Server(acceptAllClientCertificates: true), throwsArgumentError);
      expect(() => Server(allowNone: false), throwsArgumentError);
    });

    test('a certificate without a trust list is refused, not silently accept-all', () {
      expect(() => secured(), throwsArgumentError);
      expect(() => secured(trustList: []), throwsArgumentError);
      expect(
        () => Server(
          certificate: serverIdentity.certificate,
          privateKey: serverIdentity.privateKey,
          issuerList: [clientIdentity.certificate],
        ),
        throwsArgumentError,
      );
    });

    test('accept-all and a trust list contradict each other', () {
      expect(
        () => secured(trustList: [clientIdentity.certificate], acceptAllClientCertificates: true),
        throwsArgumentError,
      );
    });

    test('someone must be able to log in', () {
      expect(() => Server(allowAnonymous: false), throwsArgumentError);
      expect(() => Server(allowAnonymous: false, users: {}), throwsArgumentError);
      expect(() => Server(users: {'': 'secret'}), throwsArgumentError);
      // A trust list can log a client in (an X509 identity token), users
      // are not needed then.
      secured(trustList: [clientIdentity.certificate], allowAnonymous: false).delete();
      // Accept-all cannot: it is no identity.
      expect(() => secured(acceptAllClientCertificates: true, allowAnonymous: false), throwsArgumentError);
    });

    test('the certificate must carry the ApplicationUri the server announces', () {
      expect(
        () => Server(
          certificate: serverIdentity.certificate,
          privateKey: serverIdentity.privateKey,
          trustList: [clientIdentity.certificate],
          applicationUri: 'urn:some:other:application',
        ),
        throwsArgumentError,
      );
      // The default URI is the one the test certificates carry.
      secured(trustList: [clientIdentity.certificate], allowNone: true).delete();
      Server(
        certificate: serverIdentity.certificate,
        privateKey: serverIdentity.privateKey,
        trustList: [clientIdentity.certificate],
        applicationUri: defaultServerApplicationUri,
      ).delete();
    });

    test('the hostname and the limits are checked', () {
      expect(() => Server(hostname: ''), throwsArgumentError);
      expect(() => Server(limits: const ServerLimits(maxSessions: -1)), throwsArgumentError);
      // 0 is a lifted cap for the UInt32 fields, but open62541 compares the
      // live count against these two with >=: 0 would refuse everything.
      expect(() => Server(limits: const ServerLimits(maxSessions: 0)), throwsArgumentError);
      expect(() => Server(limits: const ServerLimits(maxSecureChannels: 0)), throwsArgumentError);
      Server(limits: const ServerLimits(maxSessions: 0xFFFF, maxSecureChannels: 0xFFFF), logLevel: _fatal).delete();
      expect(() => Server(limits: const ServerLimits(maxSessions: 0x10000)), throwsArgumentError);
      expect(() => Server(limits: const ServerLimits(maxSecureChannels: 0x10000)), throwsArgumentError);
      expect(() => Server(limits: const ServerLimits(maxNodesPerRead: -1)), throwsArgumentError);
      expect(() => Server(limits: const ServerLimits(maxMessageSize: 0x100000000)), throwsArgumentError);
    });
  });

  group('a plain Server():', () {
    late Server server;
    setUp(() => server = Server(logLevel: _fatal));
    tearDown(() => server.delete());

    test('offers SecurityPolicy#None, anonymous, no node management, open62541 limits', () {
      expect(server.endpoints, [(securityPolicyUri: securityPolicyNoneUri, securityMode: _none)]);
      expect(server.allowNone, isTrue);
      expect(server.allowAnonymous, isTrue);
      expect(server.allowUnencryptedPassword, isFalse);
      expect(server.allowClientNodeManagement, isFalse);
      expect(server.hasCertificate, isFalse);
      expect(server.acceptAllClientCertificates, isFalse);
      expect(server.hostname, isNull);
      expectLimits(server.limits, ServerLimits.defaults);
    });
  });

  group('an encrypted server with a trust list:', () {
    late Running running;

    setUpAll(() {
      running = Running(secured(trustList: [clientIdentity.certificate], users: {'alice': 'secret'}));
    });
    tearDownAll(() => running.stop());

    test('offers every secure policy in Sign and SignAndEncrypt, and no None endpoint', () {
      final endpoints = running.server.endpoints;
      expect(running.server.allowNone, isFalse);
      expect(running.server.hasCertificate, isTrue);
      expect(endpoints.map((e) => e.securityPolicyUri), isNot(contains(securityPolicyNoneUri)));
      expect(endpoints.map((e) => e.securityMode).toSet(), {_sign, _signAndEncrypt});
      expect(endpoints, contains((securityPolicyUri: _basic256Sha256, securityMode: _signAndEncrypt)));
      expect(endpoints, contains((securityPolicyUri: _basic256Sha256, securityMode: _sign)));
      expect(endpoints.length, greaterThanOrEqualTo(6), reason: 'three policies, two modes each');
    });

    for (final clientType in clientTypes) {
      group('$clientType client:', () {
        test('a trusted client activates on SignAndEncrypt and reads', () async {
          final client = await clientOf(clientType, identity: clientIdentity);
          await client.connect(running.url);
          final time = await client.read(NodeId.serverStatusCurrentTime);
          expect(time.asDateTime!.difference(DateTime.now()).abs(), lessThan(const Duration(minutes: 1)));
          if (client is Client) {
            expect(client.config.securityMode, _signAndEncrypt);
            expect(client.config.securityPolicyUri, isNot(securityPolicyNoneUri));
          }
        });

        test('a client with an untrusted certificate gets no channel', () async {
          final client = await clientOf(clientType, identity: strangerIdentity);
          await expectLater(client.connect(running.url), refusedWith(raw.UA_STATUSCODE_BADSECURITYCHECKSFAILED));
        });

        test('a client that offers only SecurityPolicy#None finds no endpoint', () async {
          final client = await clientOf(clientType);
          await expectLater(client.connect(running.url), refusedWith(raw.UA_STATUSCODE_BADIDENTITYTOKENREJECTED));
        });

        test('a username/password over the encrypted channel needs no clear-text opt-in', () async {
          expect(running.server.allowUnencryptedPassword, isFalse);
          final client = await clientOf(clientType, identity: clientIdentity, username: 'alice', password: 'secret');
          await client.connect(running.url);
          await client.read(NodeId.serverStatusCurrentTime);
        });

        test('a wrong password over the encrypted channel is refused', () async {
          final client = await clientOf(clientType, identity: clientIdentity, username: 'alice', password: 'wrong');
          await expectLater(client.connect(running.url), refusedWith(raw.UA_STATUSCODE_BADUSERACCESSDENIED));
        });
      });
    }
  });

  group('an encrypted server that accepts every client certificate, no anonymous:', () {
    late Running running;

    setUpAll(() {
      running = Running(
        secured(acceptAllClientCertificates: true, allowNone: true, allowAnonymous: false, users: {'alice': 'secret'}),
      );
    });
    tearDownAll(() => running.stop());

    test('offers the None endpoint next to the secure ones', () {
      expect(running.server.allowNone, isTrue);
      expect(running.server.acceptAllClientCertificates, isTrue);
      expect(running.server.allowAnonymous, isFalse);
      expect(running.server.endpoints, contains((securityPolicyUri: securityPolicyNoneUri, securityMode: _none)));
      expect(running.server.endpoints, contains((securityPolicyUri: _basic256Sha256, securityMode: _signAndEncrypt)));
    });

    for (final clientType in clientTypes) {
      group('$clientType client:', () {
        test('a stranger with the password activates', () async {
          final client = await clientOf(clientType, identity: strangerIdentity, username: 'alice', password: 'secret');
          await client.connect(running.url);
          await client.read(NodeId.serverStatusCurrentTime);
        });

        // No endpoint offers an anonymous UserTokenPolicy, so open62541's
        // client finds no endpoint for its token and reports
        // BadIdentityTokenRejected before sending a session request (a
        // client that sent one anyway would get BadIdentityTokenInvalid).
        test('an anonymous session over the encrypted channel is refused', () async {
          final client = await clientOf(clientType, identity: strangerIdentity);
          await expectLater(client.connect(running.url), refusedWith(raw.UA_STATUSCODE_BADIDENTITYTOKENREJECTED));
        });

        test('an anonymous session over None is refused too', () async {
          final client = await clientOf(clientType);
          await expectLater(client.connect(running.url), refusedWith(raw.UA_STATUSCODE_BADIDENTITYTOKENREJECTED));
        });
      });
    }
  });

  group('authentication over SecurityPolicy#None:', () {
    late Running running;

    setUpAll(() {
      running = Running(
        Server(
          port: 0,
          logLevel: _fatal,
          allowAnonymous: false,
          users: {'alice': 'secret'},
          allowUnencryptedPassword: true,
        ),
      );
    });
    tearDownAll(() => running.stop());

    for (final clientType in clientTypes) {
      group('$clientType client:', () {
        test('an anonymous session is refused', () async {
          expect(running.server.allowAnonymous, isFalse);
          final client = await clientOf(clientType);
          // The endpoint offers no anonymous policy: the client reports it.
          await expectLater(client.connect(running.url), refusedWith(raw.UA_STATUSCODE_BADIDENTITYTOKENREJECTED));
        });

        test('the right username/password activates (clear text, opted in on both sides)', () async {
          expect(running.server.allowUnencryptedPassword, isTrue);
          final client = await clientOf(
            clientType,
            username: 'alice',
            password: 'secret',
            allowUnencryptedPassword: true,
          );
          await client.connect(running.url);
          await client.read(NodeId.serverStatusCurrentTime);
        });

        test('a wrong password is refused', () async {
          final client = await clientOf(
            clientType,
            username: 'alice',
            password: 'wrong',
            allowUnencryptedPassword: true,
          );
          await expectLater(client.connect(running.url), refusedWith(raw.UA_STATUSCODE_BADUSERACCESSDENIED));
        });

        test('an unknown user is refused', () async {
          final client = await clientOf(
            clientType,
            username: 'bob',
            password: 'secret',
            allowUnencryptedPassword: true,
          );
          await expectLater(client.connect(running.url), refusedWith(raw.UA_STATUSCODE_BADUSERACCESSDENIED));
        });
      });
    }
  });

  group('a password over SecurityPolicy#None without the server opt-in:', () {
    late Running running;

    setUpAll(() => running = Running(Server(port: 0, logLevel: _fatal, users: {'alice': 'secret'})));
    tearDownAll(() => running.stop());

    for (final clientType in clientTypes) {
      test('$clientType client: the right username/password is refused, it would travel in clear text', () async {
        expect(running.server.allowUnencryptedPassword, isFalse);
        final client = await clientOf(
          clientType,
          username: 'alice',
          password: 'secret',
          allowUnencryptedPassword: true,
        );
        // GetEndpoints leaves the username policy out of the None endpoint
        // (src/server/ua_services_discovery.c), so the client finds no
        // endpoint for its token and reports BadIdentityTokenRejected.
        await expectLater(client.connect(running.url), refusedWith(raw.UA_STATUSCODE_BADIDENTITYTOKENREJECTED));
      });
    }
  });

  group('node management:', () {
    final hostNode = NodeId.fromNumeric(1, 61000);
    final clientNode = NodeId.fromNumeric(1, 61001);

    group('by default a client may not reshape the address space:', () {
      late Running running;

      setUpAll(() {
        running = Running(Server(port: 0, logLevel: _fatal));
        running.server.addVariableNode(
          hostNode,
          DynamicValue(value: 1, typeId: NodeId.int32, name: 'host.node'),
          accessLevel: const AccessLevelMask(read: true, write: true),
        );
      });
      tearDownAll(() => running.stop());

      test('AddNodes, DeleteNodes, AddReferences and DeleteReferences are refused', () async {
        expect(running.server.allowClientNodeManagement, isFalse);
        final client = await RawClient.connect(running.url);
        expect(await client.addObject(clientNode, 'client.object'), raw.UA_STATUSCODE_BADUSERACCESSDENIED);
        expect(await client.deleteNode(hostNode), raw.UA_STATUSCODE_BADUSERACCESSDENIED);
        final objects = NodeId.fromNumeric(0, raw.UA_NS0ID_SERVER);
        expect(await client.addOrganizes(objects, hostNode), raw.UA_STATUSCODE_BADUSERACCESSDENIED);
        expect(
          await client.deleteOrganizes(NodeId.fromNumeric(0, raw.UA_NS0ID_OBJECTSFOLDER), hostNode),
          raw.UA_STATUSCODE_BADUSERACCESSDENIED,
        );
      });

      for (final clientType in clientTypes) {
        test('$clientType client: the host node is still there, readable and writable', () async {
          final client = await clientOf(clientType);
          await client.connect(running.url);
          final before = (await client.read(hostNode)).asInt!;
          await client.write(hostNode, DynamicValue(value: before + 1, typeId: NodeId.int32));
          expect((await client.read(hostNode)).asInt, before + 1);
        });
      }

      test('the host itself still adds and deletes nodes and references', () async {
        final server = running.server;
        final another = NodeId.fromNumeric(1, 61002);
        server.addVariableNode(another, DynamicValue(value: 3, typeId: NodeId.int32, name: 'another'));
        server.addReference(
          NodeId.fromNumeric(0, raw.UA_NS0ID_SERVER),
          NodeId.fromNumeric(0, raw.UA_NS0ID_ORGANIZES),
          another,
        );
        server.deleteReference(
          NodeId.fromNumeric(0, raw.UA_NS0ID_SERVER),
          NodeId.fromNumeric(0, raw.UA_NS0ID_ORGANIZES),
          another,
        );
        final client = await clientOf('direct');
        await client.connect(running.url);
        expect((await client.read(another)).asInt, 3);
        server.deleteNode(another);
        await expectLater(client.read(another), throwsA(anything));
      });
    });

    group('allowClientNodeManagement: true restores it:', () {
      late Running running;

      setUpAll(() {
        running = Running(Server(port: 0, logLevel: _fatal, allowClientNodeManagement: true));
        running.server.addVariableNode(
          hostNode,
          DynamicValue(value: 1, typeId: NodeId.int32, name: 'host.node'),
          accessLevel: const AccessLevelMask(read: true, write: true),
        );
      });
      tearDownAll(() => running.stop());

      test('a client adds a node and a reference, and deletes both again', () async {
        expect(running.server.allowClientNodeManagement, isTrue);
        final client = await RawClient.connect(running.url);
        expect(await client.addObject(clientNode, 'client.object'), raw.UA_STATUSCODE_GOOD);
        expect(await client.addOrganizes(clientNode, hostNode), raw.UA_STATUSCODE_GOOD);
        expect(await client.deleteOrganizes(clientNode, hostNode), raw.UA_STATUSCODE_GOOD);
        expect(await client.deleteNode(clientNode), raw.UA_STATUSCODE_GOOD);
        // Gone: a second delete finds nothing.
        expect(await client.deleteNode(clientNode), raw.UA_STATUSCODE_BADNODEIDUNKNOWN);
      });
    });
  });

  group('hostname:', () {
    /// An address of this host on another interface than loopback, or null.
    Future<InternetAddress?> externalAddress() async {
      final interfaces = await NetworkInterface.list(includeLoopback: false, type: InternetAddressType.IPv4);
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (!address.isLinkLocal) return address;
        }
      }
      return null;
    }

    Future<bool> accepts(InternetAddress address, int port) async {
      try {
        final socket = await Socket.connect(address, port, timeout: const Duration(seconds: 2));
        socket.destroy();
        return true;
      } on SocketException {
        return false;
      }
    }

    test("hostname: 'localhost' binds the loopback addresses only", () async {
      final external = await externalAddress();
      if (external == null) {
        markTestSkipped('this host has no non-loopback IPv4 address to probe');
        return;
      }
      final everywhere = Running(Server(port: 0, logLevel: _fatal));
      addTearDown(everywhere.stop);
      expect(await accepts(external, everywhere.server.port), isTrue, reason: 'a default server binds all interfaces');

      final local = Running(Server(port: 0, logLevel: _fatal, hostname: 'localhost'));
      addTearDown(local.stop);
      expect(local.server.hostname, 'localhost');
      expect(await accepts(InternetAddress.loopbackIPv4, local.server.port), isTrue);
      expect(await accepts(external, local.server.port), isFalse, reason: 'bound to localhost only');
      // And it is a working server at that address.
      final client = await clientOf('direct');
      await client.connect(local.url);
      await client.read(NodeId.serverStatusCurrentTime);
    });
  });

  group('limits:', () {
    late Running running;

    setUpAll(() {
      running = Running(
        Server(port: 0, logLevel: _fatal, limits: const ServerLimits(maxSessions: 1, maxNodesPerRead: 2)),
      );
      addBasicVariables(running.server);
    });
    tearDownAll(() => running.stop());

    test('what was given is in force, the rest is the default', () {
      final limits = running.server.limits;
      expect(limits.maxSessions, 1);
      expect(limits.maxNodesPerRead, 2);
      expect(limits.maxSecureChannels, ServerLimits.defaults.maxSecureChannels);
      expect(limits.maxNodesPerWrite, ServerLimits.defaults.maxNodesPerWrite);
    });

    for (final clientType in clientTypes) {
      group('$clientType client:', () {
        test('maxSessions: 1 refuses the second session', () async {
          final first = await clientOf(clientType);
          await first.connect(running.url);
          final second = await clientOf(clientType);
          await expectLater(second.connect(running.url), refusedWith(raw.UA_STATUSCODE_BADTOOMANYSESSIONS));
        });

        test('maxNodesPerRead: 2 refuses a three-node read as a whole', () async {
          final client = await clientOf(clientType);
          await client.connect(running.url);
          const value = [AttributeId.UA_ATTRIBUTEID_VALUE];
          final two = await client.readAttribute({boolNodeId: value, intNodeId: value});
          expect(two.length, 2);
          await expectLater(
            client.readAttribute({boolNodeId: value, intNodeId: value, doubleNodeId: value}),
            refusedWith(raw.UA_STATUSCODE_BADTOOMANYOPERATIONS),
          );
        });
      });
    }
  });

  group('default limits:', () {
    test('a fresh server has every default in force, none is 0', () {
      final server = Server(logLevel: _fatal);
      addTearDown(server.delete);
      final limits = server.limits;
      expectLimits(limits, ServerLimits.defaults);
      expect(limits.maxSubscriptions, isNot(0));
      expect(limits.maxNodesPerRead, isNot(0));
      expect(limits.maxMessageSize, isNot(0));
    });

    test('ServerLimits.unlimited lifts every cap: 0 for the UInt32 fields, 65535 for sessions and channels', () {
      final server = Server(logLevel: _fatal, limits: ServerLimits.unlimited);
      addTearDown(server.delete);
      final limits = server.limits;
      expect(limits.maxSecureChannels, 0xFFFF);
      expect(limits.maxSessions, 0xFFFF);
      for (final value in [
        limits.maxSubscriptions,
        limits.maxSubscriptionsPerSession,
        limits.maxMonitoredItems,
        limits.maxMonitoredItemsPerSubscription,
        limits.maxNodesPerRead,
        limits.maxNodesPerWrite,
        limits.maxNodesPerBrowse,
        limits.maxNodesPerMethodCall,
        limits.maxMessageSize,
        limits.maxChunkCount,
      ]) {
        expect(value, 0);
      }
    });

    group('in force:', () {
      late Running running;

      setUpAll(() {
        running = Running(Server(port: 0, logLevel: _fatal));
        addBasicVariables(running.server);
      });
      tearDownAll(() => running.stop());

      // One node, its Value attribute 10 001 times: 10 001 operations in one
      // Read request (readAttribute sends the map as a single request).
      final overTheReadLimit = {
        intNodeId: List.filled(ServerLimits.defaults.maxNodesPerRead! + 1, AttributeId.UA_ATTRIBUTEID_VALUE),
      };

      for (final clientType in clientTypes) {
        group('$clientType client:', () {
          test('maxNodesPerRead refuses a 10 001-node read as a whole', () async {
            final client = await clientOf(clientType);
            await client.connect(running.url);
            await expectLater(
              client.readAttribute(overTheReadLimit),
              refusedWith(raw.UA_STATUSCODE_BADTOOMANYOPERATIONS),
            );
            // At the limit it is served.
            final atTheLimit = {
              intNodeId: List.filled(ServerLimits.defaults.maxNodesPerRead!, AttributeId.UA_ATTRIBUTEID_VALUE),
            };
            expect((await client.readAttribute(atTheLimit))[intNodeId]!.asInt, 1);
          });

          test('maxSubscriptionsPerSession refuses the 51st subscription of a session', () async {
            final client = await clientOf(clientType);
            await client.connect(running.url);
            for (var i = 0; i < ServerLimits.defaults.maxSubscriptionsPerSession!; i++) {
              await client.subscriptionCreate();
            }
            await expectLater(
              client.subscriptionCreate(),
              throwsA(predicate((e) => '$e'.contains('BadTooManySubscriptions'), 'mentions BadTooManySubscriptions')),
            );
          });
        });
      }

      test('an explicit 0 lifts the cap: maxNodesPerRead: 0 serves the 10 001-node read', () async {
        final lifted = Running(Server(port: 0, logLevel: _fatal, limits: const ServerLimits(maxNodesPerRead: 0)));
        addTearDown(lifted.stop);
        addBasicVariables(lifted.server);
        expect(lifted.server.limits.maxNodesPerRead, 0);
        final client = await clientOf('direct');
        await client.connect(lifted.url);
        expect((await client.readAttribute(overTheReadLimit))[intNodeId]!.asInt, 1);
      });
    });
  });

  test('a secured server leaves nothing on the C heap once deleted', () async {
    // Everything new at once: the certificate store with several copies of
    // each certificate, the logins, the hostname, the limits, the None
    // endpoint removal and the node-management guard. Creating a server
    // builds namespace 0 (about 100 ms) and parses the key, so every round
    // is a single server, as in server_native_memory_test.dart.
    final trustList = [for (var i = 0; i < 4; i++) clientIdentity.certificate];
    final issuerList = [for (var i = 0; i < 4; i++) strangerIdentity.certificate];
    await expectNoHeapGrowth(
      () => Server(
        logLevel: _fatal,
        certificate: serverIdentity.certificate,
        privateKey: serverIdentity.privateKey,
        trustList: trustList,
        issuerList: issuerList,
        users: {'alice': 'secret', 'bob': 'hunter2'},
        hostname: 'localhost',
        limits: const ServerLimits(maxSessions: 5, maxNodesPerRead: 100),
      ).delete(),
      warmUp: 6,
      iterations: 1,
      rounds: 21,
      maxGrowth: 600,
      attempts: 3,
    );
  });
}
