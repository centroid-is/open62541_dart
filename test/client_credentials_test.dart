import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/extensions.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'package:open62541/src/ua_allocation.dart';

/// A native server whose only identity is `operator`/`secret`, accepted over
/// SecurityPolicy#None (built from raw bindings: `Server` has no access
/// control yet).
class _RawServer {
  _RawServer() {
    using((arena) {
      final config = arena<raw.UA_ServerConfig>();
      config.ref.logging = raw.UA_Log_Stdout_new(LogLevel.UA_LOGLEVEL_FATAL);
      expect(raw.UA_ServerConfig_setMinimal(config, 0, ffi.nullptr), raw.UA_STATUSCODE_GOOD);
      final login = arena<raw.UA_UsernamePasswordLogin>();
      login.ref.username.set('operator', allocator: arena);
      login.ref.password.set('secret', allocator: arena);
      expect(raw.UA_AccessControl_default(config, false, ffi.nullptr, 1, login), raw.UA_STATUSCODE_GOOD);
      config.ref.allowNonePolicyPassword = true;
      _server = raw.UA_Server_newWithConfig(config);
    }, ua_calloc);
    expect(raw.UA_Server_run_startup(_server), raw.UA_STATUSCODE_GOOD);
    _pump = Timer.periodic(const Duration(milliseconds: 5), (_) => raw.UA_Server_run_iterate(_server, false));
  }

  late final ffi.Pointer<raw.UA_Server> _server;
  late final Timer _pump;

  String get url {
    final description = raw.UA_Server_getConfig(_server).ref.applicationDescription;
    final port = RegExp(r':(\d+)/?$').firstMatch(description.discoveryUrls[0].value)!.group(1);
    return 'opc.tcp://127.0.0.1:$port';
  }

  void delete() {
    _pump.cancel();
    raw.UA_Server_run_shutdown(_server);
    raw.UA_Server_delete(_server);
  }
}

void main() {
  final garbage = Uint8List.fromList(List.generate(64, (i) => i));
  const refused = raw.UA_STATUSCODE_BADSECURITYCHECKSFAILED;

  group('an unparseable private key', () {
    test('Client throws the status the password callback refuses with', () {
      expect(
        () => Client(certificate: garbage, privateKey: garbage, logLevel: LogLevel.UA_LOGLEVEL_FATAL),
        throwsA(isA<UaStatusException>().having((e) => e.statusCode, 'statusCode', refused)),
      );
    });

    test('ClientIsolate.create fails with it', () async {
      await expectLater(
        ClientIsolate.create(
          certificate: garbage,
          privateKey: garbage,
          logLevel: LogLevel.UA_LOGLEVEL_FATAL,
        ).timeout(const Duration(seconds: 10)),
        throwsA(isA<UaStatusException>().having((e) => e.statusCode, 'statusCode', refused)),
      );
    });
  });

  test('the history attribute bindings round-trip on a native node', () {
    final server = _RawServer();
    try {
      using((arena) {
        final currentTime = raw.UA_NODEID_NUMERIC(0, raw.UA_NS0ID_SERVER_SERVERSTATUS_CURRENTTIME);
        final historizing = arena<ffi.Bool>();
        final accessLevel = arena<ffi.Uint8>();
        expect(raw.UA_Server_writeHistorizing(server._server, currentTime, true), raw.UA_STATUSCODE_GOOD);
        expect(raw.UA_Server_readHistorizing(server._server, currentTime, historizing), raw.UA_STATUSCODE_GOOD);
        expect(historizing.value, isTrue);
        final level = raw.UA_ACCESSLEVELMASK_READ | raw.UA_ACCESSLEVELMASK_HISTORYREAD;
        expect(raw.UA_Server_writeAccessLevel(server._server, currentTime, level), raw.UA_STATUSCODE_GOOD);
        expect(raw.UA_Server_readAccessLevel(server._server, currentTime, accessLevel), raw.UA_STATUSCODE_GOOD);
        expect(accessLevel.value, level);
      }, ua_calloc);
    } finally {
      server.delete();
    }
  });

  group('ClientIsolate allowUnencryptedPassword', () {
    late _RawServer server;
    setUp(() => server = _RawServer());
    tearDown(() => server.delete());

    test('a username over None connects when allowed', () async {
      final client = await ClientIsolate.create(
        username: 'operator',
        password: 'secret',
        allowUnencryptedPassword: true,
        logLevel: LogLevel.UA_LOGLEVEL_FATAL,
      );
      try {
        await client.connect(server.url).timeout(const Duration(seconds: 10));
        expect((await client.state).sessionState, raw.UA_SessionState.UA_SESSIONSTATE_ACTIVATED);
      } finally {
        await client.delete();
      }
    });

    test('a username over None is not sent by default', () async {
      final client = await ClientIsolate.create(
        username: 'operator',
        password: 'secret',
        logLevel: LogLevel.UA_LOGLEVEL_FATAL,
      );
      try {
        // open62541 drops the password policy on a None channel without it,
        // so no endpoint suits the client.
        await expectLater(
          client.connect(server.url).timeout(const Duration(seconds: 3)),
          throwsA(
            isA<UaStatusException>().having(
              (e) => e.statusCode,
              'statusCode',
              raw.UA_STATUSCODE_BADIDENTITYTOKENREJECTED,
            ),
          ),
        );
        expect((await client.state).sessionState, isNot(raw.UA_SessionState.UA_SESSIONSTATE_ACTIVATED));
      } finally {
        await client.delete();
      }
    });
  });
}
