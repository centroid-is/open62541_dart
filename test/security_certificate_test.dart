import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

import 'package:open62541/open62541.dart';
import 'package:open62541/src/security.dart' show byteStringIn;
import 'package:open62541/src/third_party/open62541.g.dart' as raw;
import 'package:open62541/src/ua_allocation.dart';
import 'pki_fixtures.dart';

String nativeThumbprint(Certificate certificate) => using((arena) {
  final out = arena<raw.UA_String>();
  out.ref.length = 40;
  out.ref.data = arena<ffi.Uint8>(40);
  expect(raw.UA_CertificateUtils_getThumbprint(byteStringIn(arena, certificate.der), out), raw.UA_STATUSCODE_GOOD);
  return ascii.decode(out.ref.data.asTypedList(40));
}, ua_calloc);

int nativeKeyBits(Certificate certificate) => using((arena) {
  final out = arena<ffi.Size>();
  expect(raw.UA_CertificateUtils_getKeySize(byteStringIn(arena, certificate.der), out), raw.UA_STATUSCODE_GOOD);
  return out.value;
}, ua_calloc);

void main() {
  const uri = 'urn:open62541.dart.test.generated';
  late CertificateAndKey generated;
  late DateTime generatedAt;

  setUpAll(() {
    generatedAt = DateTime.now().toUtc();
    generated = createSelfSignedCertificate(
      applicationUri: uri,
      subject: ['O=open62541_dart tests', 'CN=generated'],
      dnsNames: ['localhost'],
      ipAddresses: ['127.0.0.1'],
      validity: const Duration(days: 30),
    );
  });

  group('createSelfSignedCertificate', () {
    test('carries the applicationUri and nothing else as its URI', () {
      expect(generated.certificate.hasApplicationUri(uri), isTrue);
      expect(generated.certificate.hasApplicationUri('urn:open62541.dart.test.other'), isFalse);
      expect(generated.certificate.hasApplicationUri('$uri/'), isFalse);
      expect(generated.certificate.applicationUris, [uri]);
    });

    test('has the subject, key size and validity asked for', () {
      expect(generated.certificate.subject, 'O=open62541_dart tests, CN=generated');
      expect(nativeKeyBits(generated.certificate), 2048);
      // open62541 skews notAfter by the host's UTC offset (mktime over gmtime).
      final expected = generatedAt.add(const Duration(days: 30));
      expect(generated.certificate.notAfter.difference(expected).inHours.abs(), lessThanOrEqualTo(14));
      expect(generated.certificate.notAfter.isUtc, isTrue);
    });

    test('returns a DER key that matches the certificate', () {
      expect(generated.privateKey.first, 0x30);
      expect(checkKeyPair(generated.certificate, generated.privateKey), isTrue);
    });

    test('rejects what UA_CreateCertificate would drop or misencode', () {
      expect(
        () => createSelfSignedCertificate(applicationUri: uri, subject: ['CN=x'], ipAddresses: ['::1']),
        throwsArgumentError,
      );
      expect(
        () => createSelfSignedCertificate(applicationUri: uri, subject: ['CN=x'], ipAddresses: ['host']),
        throwsArgumentError,
      );
      expect(() => createSelfSignedCertificate(applicationUri: uri, subject: []), throwsArgumentError);
      expect(() => createSelfSignedCertificate(applicationUri: uri, subject: ['plain']), throwsArgumentError);
      expect(() => createSelfSignedCertificate(applicationUri: '', subject: ['CN=x']), throwsArgumentError);
      expect(
        () => createSelfSignedCertificate(applicationUri: uri, subject: ['CN=x'], keyBits: 1024),
        throwsArgumentError,
      );
      expect(
        () => createSelfSignedCertificate(applicationUri: uri, subject: ['CN=x'], validity: const Duration(hours: 1)),
        throwsArgumentError,
      );
      expect(
        () =>
            createSelfSignedCertificate(applicationUri: uri, subject: ['CN=x'], validity: const Duration(days: 65536)),
        throwsArgumentError,
      );
    });
  });

  group('Certificate', () {
    test('the SHA-1 thumbprint is sha1(der) and what open62541 computes', () {
      final certificate = generated.certificate;
      expect(certificate.sha1Thumbprint, sha1.convert(certificate.der).toString().toUpperCase());
      expect(certificate.sha1Thumbprint, nativeThumbprint(certificate));
      expect(certificate.sha256Thumbprint, sha256.convert(certificate.der).toString().toUpperCase());
      final fixture = pkiCertificate('server');
      expect(fixture.sha1Thumbprint, nativeThumbprint(fixture));
    });

    test('PEM and DER round-trip', () {
      final certificate = pkiCertificate('server');
      final pem = certificate.toPem();
      expect(pem, startsWith('-----BEGIN CERTIFICATE-----\n'));
      expect(pem.split('\n').every((line) => line.length <= 64), isTrue);
      final back = Certificate.fromPem('leading text\n$pem\ntrailing');
      expect(back.der, certificate.der);
      expect(back, certificate);
      expect(back.hashCode, certificate.hashCode);
      expect(back, isNot(pkiCertificate('client')));
    });

    test('reads the fixtures', () {
      expect(pkiCertificate('ca').subject, 'CN=open62541-dart test CA, O=open62541_dart tests');
      expect(pkiCertificate('server').hasApplicationUri(fixtureServerUri), isTrue);
      expect(pkiCertificate('client').hasApplicationUri(fixtureClientUri), isTrue);
      expect(pkiCertificate('client').hasApplicationUri(fixtureServerUri), isFalse);
      expect(pkiCertificate('expired').notAfter, DateTime.utc(2020, 12, 31));
      expect(pkiCertificate('server').applicationUris, [fixtureServerUri]);
      expect(pkiCertificate('ca').applicationUris, isEmpty);
    });

    test('is validated on construction', () {
      expect(() => Certificate.fromDer(Uint8List(0)), throwsArgumentError);
      expect(() => Certificate.fromDer(Uint8List.fromList([0x30, 0x82, 1, 2, 3, 4])), throwsArgumentError);
      final truncated = pkiBytes('server.der').sublist(0, 400);
      expect(() => Certificate.fromDer(truncated), throwsArgumentError);
      expect(() => Certificate.fromDer(pkiBytes('ca.crl')), throwsArgumentError);
      expect(() => Certificate.fromPem('no pem here'), throwsArgumentError);
      expect(
        () => Certificate.fromPem('-----BEGIN CERTIFICATE-----\n!!!\n-----END CERTIFICATE-----'),
        throwsArgumentError,
      );
    });

    test('der is read-only', () {
      expect(() => generated.certificate.der[0] = 0, throwsUnsupportedError);
    });
  });

  group('keys', () {
    test('checkKeyPair refuses another key', () {
      expect(checkKeyPair(pkiCertificate('client'), pkiBytes('client_key.der')), isTrue);
      expect(checkKeyPair(pkiCertificate('client'), pkiBytes('server_key.der')), isFalse);
      expect(checkKeyPair(generated.certificate, pkiBytes('client_key.der')), isFalse);
      expect(checkKeyPair(generated.certificate, Uint8List.fromList([1, 2, 3])), isFalse);
    });

    test('an encrypted PEM key decrypts with its password only', () {
      final encrypted = pkiBytes('client_key_encrypted.pem');
      expect(checkKeyPair(pkiCertificate('client'), encrypted), isFalse);
      final der = decryptPrivateKey(encrypted, password: fixtureKeyPassword);
      expect(der.first, 0x30);
      expect(checkKeyPair(pkiCertificate('client'), der), isTrue);
      const refused = raw.UA_STATUSCODE_BADSECURITYCHECKSFAILED;
      final isRefused = throwsA(isA<UaStatusException>().having((e) => e.statusCode, 'statusCode', refused));
      expect(() => decryptPrivateKey(encrypted, password: 'wrong'), isRefused);
      expect(() => decryptPrivateKey(encrypted), isRefused);
      expect(() => decryptPrivateKey(Uint8List.fromList([1, 2, 3])), isRefused);
      expect(() => decryptPrivateKey(Uint8List(0)), isRefused);
    });

    test('a DER key passes through unchanged', () {
      final der = pkiBytes('client_key.der');
      expect(decryptPrivateKey(der), der);
      expect(decryptPrivateKey(der, password: 'ignored'), der);
    });
  });

  test('TrustList', () {
    const empty = TrustList();
    expect(empty.acceptsAll, isFalse);
    expect(empty.trusted, isEmpty);
    expect(const TrustList.acceptAll().acceptsAll, isTrue);
  });

  test('SecurityPolicy and UserTokenType', () {
    expect(
      SecurityPolicy.fromUri('http://opcfoundation.org/UA/SecurityPolicy#Aes256_Sha256_RsaPss'),
      SecurityPolicy.aes256Sha256RsaPss,
    );
    expect(SecurityPolicy.fromUri('http://opcfoundation.org/UA/SecurityPolicy#Basic128Rsa15'), isNull);
    expect(SecurityPolicy.secure, isNot(contains(SecurityPolicy.none)));
    expect(SecurityPolicy.secure, hasLength(3));
    expect(UserTokenType.fromValue(raw.UA_UserTokenType.UA_USERTOKENTYPE_CERTIFICATE.value), UserTokenType.certificate);
    expect(() => UserTokenType.fromValue(9), throwsArgumentError);
  });
}
