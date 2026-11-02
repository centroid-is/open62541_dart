// A server private key open62541 could not load made it ask for the password
// on stdin, which blocks the process, or, for a DER-tagged key it copies
// unparsed, left the server with the None endpoint alone. The constructor
// refuses all of them.

import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'secure_fixtures.dart';

/// A PKCS#8 EncryptedPrivateKeyInfo (PBES2) around random bytes, DER.
Uint8List _encryptedKey() {
  List<int> tlv(int tag, List<int> body) {
    final length = body.length;
    final header = length < 0x80 ? [length] : [0x82, length >> 8, length & 0xff];
    return [tag, ...header, ...body];
  }

  const pbes2 = [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x05, 0x0d];
  final random = Random(1);
  final algorithm = tlv(0x30, [...tlv(0x06, pbes2), ...tlv(0x30, [])]);
  final data = tlv(0x04, List.generate(1200, (_) => random.nextInt(256)));
  return Uint8List.fromList(tlv(0x30, [...algorithm, ...data]));
}

/// A DER SEQUENCE that is not a key: open62541 hands it to the policies
/// unparsed, and each of them fails to build its context.
Uint8List _sequenceOfNoise() {
  final random = Random(2);
  const header = [0x30, 0x82, 0x01, 0x02, 0x02, 0x01, 0x00];
  return Uint8List.fromList([...header, ...List.generate(255, (_) => random.nextInt(256))]);
}

void main() {
  late Identity identity;
  setUpAll(() => identity = createIdentity('server private key test'));

  Server create(Uint8List key) => Server(
    port: 0,
    certificate: identity.certificate,
    privateKey: key,
    acceptAllClientCertificates: true,
    logLevel: LogLevel.UA_LOGLEVEL_FATAL,
  );

  final refused = throwsA(
    isA<UaStatusException>().having((e) => e.statusCode, 'statusCode', raw.UA_STATUSCODE_BADSECURITYCHECKSFAILED),
  );

  test('an encrypted key is an ArgumentError before any native call', () {
    expect(() => create(_encryptedKey()), throwsArgumentError);
  });

  test('a key that does not parse is refused by the password callback', () {
    expect(() => create(Uint8List.fromList(List.generate(64, (i) => i))), refused);
  });

  test('a DER key the policies cannot use is refused instead of a None-only server', () {
    expect(() => create(_sequenceOfNoise()), refused);
  });
}
