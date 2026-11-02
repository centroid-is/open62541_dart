// A private key open62541 cannot load without a password made it ask on
// stdin ("Private key requires a password. Enter and press return:"), which
// blocks the process, and the status of UA_ClientConfig_setDefaultEncryption
// was ignored, so a key it refused left a client without its secure policies.
// Now an encrypted key is an ArgumentError before any native call, a key
// open62541 refuses is a UaStatusException from the constructor, and the
// prompt is replaced by a callback that hands over no password.

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'common.dart';
import 'secure_fixtures.dart';

/// A PKCS#8 EncryptedPrivateKeyInfo (PBES2) around random bytes, DER: the
/// shape openssl writes for `pkcs8 -topk8 -outform DER` with a password.
Uint8List _handMadeEncryptedKey() {
  List<int> tlv(int tag, List<int> body) {
    final length = body.length;
    final header = length < 0x80 ? [length] : [0x82, length >> 8, length & 0xff];
    return [tag, ...header, ...body];
  }

  // 1.2.840.113549.1.5.13 (PBES2)
  const pbes2 = [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x05, 0x0d];
  final random = Random(1);
  final algorithm = tlv(0x30, [...tlv(0x06, pbes2), ...tlv(0x30, [])]);
  final data = tlv(0x04, List.generate(1200, (_) => random.nextInt(256)));
  return Uint8List.fromList(tlv(0x30, [...algorithm, ...data]));
}

/// [key] (DER) encrypted by openssl as PKCS#8 DER, PKCS#8 PEM and legacy
/// PEM; null when openssl is not on the PATH.
Future<Map<String, Uint8List>?> _opensslEncryptedKeys(Uint8List key) async {
  final dir = await Directory.systemTemp.createTemp('open62541_private_key_');
  try {
    Future<bool> openssl(List<String> args) async {
      final ProcessResult result;
      try {
        result = await Process.run('openssl', args, workingDirectory: dir.path);
      } on ProcessException {
        return false;
      }
      if (result.exitCode != 0) fail('openssl ${args.join(' ')}: ${result.stderr}');
      return true;
    }

    if (!await openssl(['version'])) return null;
    await File('${dir.path}/key.der').writeAsBytes(key);
    const pass = ['-passout', 'pass:secret'];
    await openssl([
      'pkcs8',
      '-topk8',
      '-inform',
      'DER',
      '-in',
      'key.der',
      '-outform',
      'DER',
      '-out',
      'p8.der',
      ...pass,
    ]);
    await openssl(['pkcs8', '-topk8', '-inform', 'DER', '-in', 'key.der', '-out', 'p8.pem', ...pass]);
    await openssl([
      'rsa',
      '-inform',
      'DER',
      '-in',
      'key.der',
      '-aes256',
      '-traditional',
      '-out',
      'legacy.pem',
      ...pass,
    ]);
    return {
      'PKCS#8 DER': await File('${dir.path}/p8.der').readAsBytes(),
      'PKCS#8 PEM': await File('${dir.path}/p8.pem').readAsBytes(),
      'legacy PEM': await File('${dir.path}/legacy.pem').readAsBytes(),
    };
  } finally {
    await dir.delete(recursive: true);
  }
}

/// Makes a client of [clientType] with [privateKey] and deletes it again.
Future<void> _create(String clientType, Identity identity, Uint8List privateKey) async {
  const mode = MessageSecurityMode.UA_MESSAGESECURITYMODE_SIGNANDENCRYPT;
  switch (clientType) {
    case 'direct':
      await Client(
        securityMode: mode,
        certificate: identity.certificate,
        privateKey: privateKey,
        acceptAllCertificates: true,
        logLevel: LogLevel.UA_LOGLEVEL_FATAL,
      ).delete();
    case 'isolate':
      await (await ClientIsolate.create(
        securityMode: mode,
        certificate: identity.certificate,
        privateKey: privateKey,
        acceptAllCertificates: true,
        logLevel: LogLevel.UA_LOGLEVEL_FATAL,
      )).delete();
    default:
      throw ArgumentError(clientType);
  }
}

Matcher _refusedWith(int status) => throwsA(isA<UaStatusException>().having((e) => e.statusCode, 'statusCode', status));

void main() {
  late Identity identity;
  Map<String, Uint8List>? opensslKeys;

  setUpAll(() async {
    identity = createIdentity('private key test');
    opensslKeys = await _opensslEncryptedKeys(identity.privateKey);
  });

  for (final clientType in clientTypes) {
    group('$clientType client: private key', () {
      test('a valid key makes a client', () async {
        await _create(clientType, identity, identity.privateKey);
      });

      test('an encrypted PKCS#8 key (DER, built by hand) is an ArgumentError', () async {
        await expectLater(_create(clientType, identity, _handMadeEncryptedKey()), throwsArgumentError);
      });

      for (final kind in ['PKCS#8 DER', 'PKCS#8 PEM', 'legacy PEM']) {
        test('an encrypted key from openssl ($kind) is an ArgumentError', () async {
          final key = opensslKeys?[kind];
          if (key == null) {
            markTestSkipped('openssl is not on the PATH');
            return;
          }
          await expectLater(_create(clientType, identity, key), throwsArgumentError);
        });
      }

      // Not DER: open62541 tries to parse it without a password, then asks
      // the password callback (before: stdin), then fails.
      test('a PEM key that does not parse is Bad_SecurityChecksFailed, without a prompt', () async {
        final key = Uint8List.fromList(
          '-----BEGIN PRIVATE KEY-----\nbm90IGEga2V5\n-----END PRIVATE KEY-----\n'.codeUnits,
        );
        await expectLater(_create(clientType, identity, key), _refusedWith(raw.UA_STATUSCODE_BADSECURITYCHECKSFAILED));
      });

      // open62541's status for these is Bad_OutOfMemory: its mbedTLS key
      // copy adds the terminating NUL only to PEM, and the length check that
      // follows takes the missing byte for a failed allocation.
      test('bytes that are no key are a UaStatusException, without a prompt', () async {
        final key = Uint8List.fromList('not a key'.codeUnits);
        await expectLater(_create(clientType, identity, key), _refusedWith(raw.UA_STATUSCODE_BADOUTOFMEMORY));
      });

      // DER: setDefaultEncryption takes it verbatim and returns Good; every
      // secure policy then fails to load it.
      test('a DER key that does not parse is Bad_SecurityChecksFailed', () async {
        final key = Uint8List.fromList([0x30, 0x03, 0x02, 0x01, 0x00]);
        await expectLater(_create(clientType, identity, key), _refusedWith(raw.UA_STATUSCODE_BADSECURITYCHECKSFAILED));
      });
    });
  }
}
