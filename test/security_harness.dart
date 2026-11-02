import 'dart:async';
import 'dart:typed_data';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;

const securedServerUri = 'urn:open62541.dart.test.secured';
const signAndEncrypt = MessageSecurityMode.UA_MESSAGESECURITYMODE_SIGNANDENCRYPT;

/// A started [Server], pumped by a timer on this isolate until [delete].
class PumpedServer {
  PumpedServer(this.server) {
    server.start();
    _pump = Timer.periodic(const Duration(milliseconds: 2), (_) => server.runIterate());
  }

  /// A server with [identity] as its certificate, trusting [trustList].
  PumpedServer.secured(
    CertificateAndKey identity, {
    required List<Uint8List> trustList,
    bool? allowNone,
    bool allowUnencryptedPassword = false,
    bool allowClientNodeManagement = false,
    AccessControl? accessControl,
  }) : this(
         Server(
           port: 0,
           logLevel: LogLevel.UA_LOGLEVEL_FATAL,
           applicationUri: securedServerUri,
           certificate: identity.certificate.der,
           privateKey: identity.privateKey,
           trustList: trustList,
           allowNone: allowNone,
           allowUnencryptedPassword: allowUnencryptedPassword,
           allowClientNodeManagement: allowClientNodeManagement,
           accessControl: accessControl,
         ),
       );

  final Server server;
  late final Timer _pump;

  String get url => 'opc.tcp://127.0.0.1:${server.port}';

  void delete() {
    _pump.cancel();
    server.shutdown();
    server.delete();
  }
}

/// Connects [client] and answers Good once the session is activated, or
/// the first bad connect status the client reports.
Future<int> connectStatus(Client client, String url) async {
  final result = Completer<int>();
  final states = client.config.stateStream.listen((state) {
    if (result.isCompleted) return;
    if (state.sessionState == raw.UA_SessionState.UA_SESSIONSTATE_ACTIVATED) {
      result.complete(raw.UA_STATUSCODE_GOOD);
    } else if (state.recoveryStatus != raw.UA_STATUSCODE_GOOD) {
      result.complete(state.recoveryStatus);
    }
  });
  client.connect(url).ignore();
  final pump = Timer.periodic(const Duration(milliseconds: 2), (_) => client.runIterate(Duration.zero));
  try {
    return await result.future.timeout(const Duration(seconds: 15));
  } finally {
    pump.cancel();
    await states.cancel();
  }
}

Future<void> deleteClient(Client client) async {
  try {
    client.disconnect();
  } catch (_) {}
  await client.delete();
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
