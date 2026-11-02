import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io' show InternetAddress, InternetAddressType;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';

import 'common.dart';
import 'extensions.dart';
import 'third_party/open62541.g.dart' as raw;
import 'types/errors.dart';
import 'ua_allocation.dart';

/// An OPC UA SecurityPolicy, by its Part 7 URI.
///
/// Only the policies this package's mbedTLS build serves are listed. The
/// deprecated Basic128Rsa15 and Basic256 and the ECC policies are compiled
/// into open62541 but never offered (their URIs still show up in
/// GetEndpoints answers of other servers, as plain strings).
enum SecurityPolicy {
  none('http://opcfoundation.org/UA/SecurityPolicy#None'),
  basic256Sha256('http://opcfoundation.org/UA/SecurityPolicy#Basic256Sha256'),
  aes128Sha256RsaOaep('http://opcfoundation.org/UA/SecurityPolicy#Aes128_Sha256_RsaOaep'),
  aes256Sha256RsaPss('http://opcfoundation.org/UA/SecurityPolicy#Aes256_Sha256_RsaPss');

  const SecurityPolicy(this.uri);

  /// The policy's URI, as it appears in an EndpointDescription.
  final String uri;

  /// The policies that sign and encrypt and are not deprecated.
  static const Set<SecurityPolicy> secure = {basic256Sha256, aes128Sha256RsaOaep, aes256Sha256RsaPss};

  /// The policy with [uri], or `null` for one this package does not serve.
  static SecurityPolicy? fromUri(String uri) {
    for (final policy in values) {
      if (policy.uri == uri) return policy;
    }
    return null;
  }
}

/// An X.509 certificate, held as DER.
///
/// Both constructors parse the certificate with open62541's crypto backend
/// and throw an [ArgumentError] if it cannot, so a [Certificate] is valid by
/// construction.
final class Certificate {
  Certificate._(this.der, this.subject, this.notAfter, this.keyBits);

  /// A certificate from its DER encoding.
  factory Certificate.fromDer(Uint8List der) {
    if (der.isEmpty || der[0] != 0x30) {
      throw ArgumentError.value('${der.length} bytes', 'der', 'not a DER-encoded certificate');
    }
    final copy = Uint8List.fromList(der);
    return using((arena) {
      final bytes = byteStringIn(arena, copy);
      final expiry = arena<ffi.Int64>();
      final status = raw.UA_CertificateUtils_getExpirationDate(bytes, expiry);
      if (status != raw.UA_STATUSCODE_GOOD) {
        throw ArgumentError.value(
          '${der.length} bytes',
          'der',
          'not an X.509 certificate (${statusCodeToString(status)})',
        );
      }
      final subject = arena<raw.UA_String>();
      final subjectStatus = raw.UA_CertificateUtils_getSubjectName(bytes, subject);
      if (subjectStatus != raw.UA_STATUSCODE_GOOD) {
        throw ArgumentError.value(
          '${der.length} bytes',
          'der',
          'no subject name (${statusCodeToString(subjectStatus)})',
        );
      }
      final subjectName = utf8.decode(subject.ref.data.asTypedList(subject.ref.length), allowMalformed: true);
      raw.UA_ByteString_clear(subject);
      final keySize = arena<ffi.Size>();
      final keyStatus = raw.UA_CertificateUtils_getKeySize(bytes, keySize);
      return Certificate._(
        copy.asUnmodifiableView(),
        subjectName,
        uaDateTimeToDateTime(expiry.value) ?? DateTime.fromMicrosecondsSinceEpoch(0, isUtc: true),
        keyStatus == raw.UA_STATUSCODE_GOOD ? keySize.value : 0,
      );
    }, ua_calloc);
  }

  /// The first `CERTIFICATE` block of a PEM text.
  factory Certificate.fromPem(String pem) {
    final match = _pemCertificate.firstMatch(pem);
    if (match == null) {
      throw ArgumentError.value(pem, 'pem', 'no -----BEGIN CERTIFICATE----- block');
    }
    final Uint8List der;
    try {
      der = base64.decode(match.group(1)!.replaceAll(RegExp(r'\s'), ''));
    } on FormatException catch (e) {
      throw ArgumentError.value(pem, 'pem', 'invalid base64 (${e.message})');
    }
    return Certificate.fromDer(der);
  }

  static final _pemCertificate = RegExp(r'-----BEGIN CERTIFICATE-----([\s\S]*?)-----END CERTIFICATE-----');

  /// The DER encoding (read-only).
  final Uint8List der;

  /// The subject's distinguished name as mbedTLS prints it, e.g.
  /// `CN=open62541-dart test server, O=open62541_dart tests`.
  final String subject;

  /// The end of the validity period (UTC).
  final DateTime notAfter;

  /// The size of the public key in bits (`UA_CertificateUtils_getKeySize`),
  /// 0 for a key open62541 cannot size.
  final int keyBits;

  /// The `URI:` SubjectAltNames, in certificate order (an OPC UA application
  /// certificate carries one, the ApplicationUri). Empty when there is none.
  late final List<String> applicationUris = List.unmodifiable(_uriSubjectAltNames(der));

  /// The OPC UA certificate thumbprint: SHA-1 over [der], uppercase hex, as
  /// `EndpointDescription.certificateThumbprint` and OPC UA tooling show it.
  late final String sha1Thumbprint = sha1.convert(der).toString().toUpperCase();

  /// SHA-256 over [der], uppercase hex, for display.
  late final String sha256Thumbprint = sha256.convert(der).toString().toUpperCase();

  /// Whether a `URI:` SubjectAltName of this certificate is exactly [uri]:
  /// the ApplicationUri an OPC UA application using it must announce.
  bool hasApplicationUri(String uri) => using((arena) {
    final value = arena<raw.UA_String>()..ref.set(uri, allocator: arena);
    return raw.UA_CertificateUtils_verifyApplicationUri(byteStringIn(arena, der), value) == raw.UA_STATUSCODE_GOOD;
  }, ua_calloc);

  /// The certificate as a PEM `CERTIFICATE` block.
  String toPem() {
    final body = base64.encode(der);
    final lines = [for (var i = 0; i < body.length; i += 64) body.substring(i, (i + 64).clamp(0, body.length))];
    return '-----BEGIN CERTIFICATE-----\n${lines.join('\n')}\n-----END CERTIFICATE-----\n';
  }

  @override
  bool operator ==(Object other) =>
      other is Certificate && other.der.length == der.length && other.sha1Thumbprint == sha1Thumbprint;

  @override
  int get hashCode => sha1Thumbprint.hashCode;

  @override
  String toString() => 'Certificate($subject, SHA-1 $sha1Thumbprint)';
}

/// A certificate with its private key (DER, unencrypted).
final class CertificateAndKey {
  const CertificateAndKey(this.certificate, this.privateKey);

  final Certificate certificate;
  final Uint8List privateKey;
}

/// Creates a self-signed RSA application instance certificate with open62541's
/// `UA_CreateCertificate`, for an OPC UA server or client to present.
///
/// * [applicationUri] goes into the `URI:` SubjectAltName; the application
///   must announce exactly this ApplicationUri.
/// * [subject] are the distinguished name's elements, e.g.
///   `['O=Centroid', 'CN=CentroidM a1@host']`.
/// * [dnsNames] and [ipAddresses] become `DNS:` and `IP:` SubjectAltNames;
///   only IPv4 addresses can be encoded.
/// * [keyBits] is the RSA key size; the RSA security policies accept 2048 to
///   4096 bits.
/// * [validity] is counted in whole days from now (1 to 65535).
///
/// The certificate is a leaf (`CA:FALSE`) with the serverAuth and clientAuth
/// extended key usages, so one certificate serves both roles. Its validity
/// starts at the current time, so a peer whose clock lags rejects it as not
/// yet valid for a while. **Its serial number is always 1**
/// (open62541's mbedTLS backend hard-codes it): certificates made by this
/// function differ only in subject and key, so give each application a unique
/// subject. Key generation blocks the calling isolate (seconds for 4096 bits).
CertificateAndKey createSelfSignedCertificate({
  required String applicationUri,
  required List<String> subject,
  List<String> dnsNames = const [],
  List<String> ipAddresses = const [],
  int keyBits = 2048,
  Duration validity = const Duration(days: 365 * 5),
}) {
  if (applicationUri.isEmpty) {
    throw ArgumentError.value(applicationUri, 'applicationUri', 'must not be empty');
  }
  if (subject.isEmpty || subject.any((element) => !element.contains('='))) {
    throw ArgumentError.value(subject, 'subject', 'needs at least one element, each KEY=value');
  }
  if (keyBits < 2048 || keyBits > 4096) {
    throw ArgumentError.value(keyBits, 'keyBits', 'must be 2048 to 4096');
  }
  final days = validity.inDays;
  if (days < 1 || days > 65535) {
    throw ArgumentError.value(validity, 'validity', 'must be 1 to 65535 whole days');
  }
  for (final ip in ipAddresses) {
    // UA_CreateCertificate encodes four bytes and drops anything else.
    if (InternetAddress.tryParse(ip)?.type != InternetAddressType.IPv4) {
      throw ArgumentError.value(ip, 'ipAddresses', 'not an IPv4 address');
    }
  }
  final altNames = [
    'URI:$applicationUri',
    for (final dns in dnsNames) 'DNS:$dns',
    for (final ip in ipAddresses) 'IP:$ip',
  ];

  return using((arena) {
    final params = _keyValueMap(arena, {'key-size-bits': keyBits, 'expires-in-days': days});
    // A zeroed logger is a silent one; the status code is what we report.
    final logger = arena<raw.UA_Logger>();
    final key = arena<raw.UA_ByteString>();
    final cert = arena<raw.UA_ByteString>();
    final status = raw.UA_CreateCertificate(
      logger,
      _uaStrings(arena, subject),
      subject.length,
      _uaStrings(arena, altNames),
      altNames.length,
      raw.UA_CertificateFormat.UA_CERTIFICATEFORMAT_DER,
      params,
      key,
      cert,
    );
    try {
      if (status != raw.UA_STATUSCODE_GOOD) {
        throw UaStatusException(status);
      }
      return CertificateAndKey(
        Certificate.fromDer(Uint8List.fromList(cert.ref.asTypedList())),
        Uint8List.fromList(key.ref.asTypedList()),
      );
    } finally {
      raw.UA_ByteString_clear(key);
      raw.UA_ByteString_clear(cert);
    }
  }, ua_calloc);
}

/// The DER form of [privateKey] (DER or PEM, PKCS#1 or PKCS#8), decrypted
/// with [password] if it is an encrypted PEM key
/// (`UA_CertificateUtils_decryptPrivateKey`).
///
/// open62541 decrypts PEM only: a DER key, encrypted or not, comes back
/// unchanged. Throws a [UaStatusException] (`BadSecurityChecksFailed`) for a
/// wrong password or a key that does not parse.
Uint8List decryptPrivateKey(Uint8List privateKey, {String? password}) => using((arena) {
  // open62541 reports bytes that are neither DER nor PEM as out of memory.
  if (privateKey.isEmpty || (privateKey[0] != 0x30 && !latin1.decode(privateKey).contains('-----BEGIN'))) {
    throw const UaStatusException(raw.UA_STATUSCODE_BADSECURITYCHECKSFAILED);
  }
  final out = arena<raw.UA_ByteString>();
  final status = raw.UA_CertificateUtils_decryptPrivateKey(
    byteStringIn(arena, privateKey).ref,
    byteStringIn(arena, utf8.encode(password ?? '')).ref,
    out,
  );
  try {
    if (status != raw.UA_STATUSCODE_GOOD) {
      throw UaStatusException(status);
    }
    return Uint8List.fromList(out.ref.asTypedList());
  } finally {
    if (out.ref.length > 0) out.ref.asTypedList().fillRange(0, out.ref.length, 0);
    raw.UA_ByteString_clear(out);
  }
}, ua_calloc);

/// Whether [privateKey] (unencrypted DER or PEM) is the key of [certificate].
bool checkKeyPair(Certificate certificate, Uint8List privateKey) => using(
  (arena) =>
      raw.UA_CertificateUtils_checkKeyPair(byteStringIn(arena, certificate.der), byteStringIn(arena, privateKey)) ==
      raw.UA_STATUSCODE_GOOD,
  ua_calloc,
);

/// The certificates the certificate group [group] refused, oldest first
/// (empty for a group without a rejected list, such as AcceptAll). Entries
/// that do not parse as a certificate are left out.
List<Certificate> rejectedCertificates(raw.UA_CertificateGroup group) {
  final getRejectedList = group.getRejectedList;
  if (getRejectedList == ffi.nullptr) return const [];
  return using((arena) {
    // The plugin reads the group's context only, which the copy shares.
    final copy = arena<raw.UA_CertificateGroup>()..ref = group;
    final list = arena<ffi.Pointer<raw.UA_ByteString>>();
    final size = arena<ffi.Size>();
    final status = getRejectedList
        .asFunction<
          int Function(
            ffi.Pointer<raw.UA_CertificateGroup>,
            ffi.Pointer<ffi.Pointer<raw.UA_ByteString>>,
            ffi.Pointer<ffi.Size>,
          )
        >()(copy, list, size);
    if (status != raw.UA_STATUSCODE_GOOD) throw UaStatusException(status);
    final result = <Certificate>[];
    for (var i = 0; i < size.value; i++) {
      try {
        result.add(Certificate.fromDer(Uint8List.fromList(list.value[i].asTypedList())));
      } on ArgumentError {
        continue;
      }
    }
    raw.UA_Array_delete(list.value.cast(), size.value, getTypeByIndex(raw.UA_TYPES_BYTESTRING));
    return result;
  }, ua_calloc);
}

/// The leaf of a certificate chain (concatenated DER), or `null` if [chain]
/// is empty or does not parse.
Certificate? leafCertificate(Uint8List chain) {
  if (chain.isEmpty) return null;
  try {
    final (_, _, end) = _derElement(chain, 0);
    return Certificate.fromDer(chain.sublist(0, end));
  } on Error {
    return null;
  }
}

/// A `UA_ByteString` in [arena] holding a copy of [bytes].
ffi.Pointer<raw.UA_ByteString> byteStringIn(Arena arena, List<int> bytes) {
  final s = arena<raw.UA_ByteString>();
  s.ref.length = bytes.length;
  if (bytes.isNotEmpty) {
    s.ref.data = arena<ffi.Uint8>(bytes.length)..asTypedList(bytes.length).setAll(0, bytes);
  }
  return s;
}

ffi.Pointer<raw.UA_String> _uaStrings(Arena arena, List<String> values) {
  final array = arena<raw.UA_String>(values.length);
  for (var i = 0; i < values.length; i++) {
    array[i].set(values[i], allocator: arena);
  }
  return array;
}

/// A `UA_KeyValueMap` in [arena] of UInt16 parameters, which open62541 reads
/// during the call it is passed to.
ffi.Pointer<raw.UA_KeyValueMap> _keyValueMap(Arena arena, Map<String, int> entries) {
  final pairs = arena<raw.UA_KeyValuePair>(entries.length);
  var i = 0;
  for (final MapEntry(key: name, value: value) in entries.entries) {
    final pair = pairs[i++];
    pair.key.namespaceIndex = 0;
    pair.key.name.set(name, allocator: arena);
    pair.value.type = getTypeByIndex(raw.UA_TYPES_UINT16);
    pair.value.storageTypeAsInt = raw.UA_VariantStorageType.UA_VARIANT_DATA_NODELETE.value;
    pair.value.data = (arena<ffi.Uint16>()..value = value).cast();
  }
  final map = arena<raw.UA_KeyValueMap>();
  map.ref.mapSize = entries.length;
  map.ref.map = pairs;
  return map;
}

/// One DER element: its tag, and where its content starts and ends.
(int, int, int) _derElement(Uint8List b, int offset) {
  final tag = b[offset];
  var length = b[offset + 1];
  var start = offset + 2;
  if (length & 0x80 != 0) {
    final count = length & 0x7F;
    length = 0;
    for (var i = 0; i < count; i++) {
      length = (length << 8) | b[start++];
    }
  }
  if (start + length > b.length) throw RangeError('DER element overruns its parent');
  return (tag, start, start + length);
}

/// The URI GeneralNames of the SubjectAltName extension (2.5.29.17), walking
/// Certificate > TBSCertificate > [3] Extensions.
List<String> _uriSubjectAltNames(Uint8List der) {
  const sanOid = [0x55, 0x1D, 0x11];
  try {
    final (_, certStart, _) = _derElement(der, 0);
    final (_, tbsStart, tbsEnd) = _derElement(der, certStart);
    for (var p = tbsStart; p < tbsEnd;) {
      final (tag, start, end) = _derElement(der, p);
      p = end;
      if (tag != 0xA3) continue;
      final (_, extsStart, extsEnd) = _derElement(der, start);
      for (var e = extsStart; e < extsEnd;) {
        final (_, extStart, extEnd) = _derElement(der, e);
        e = extEnd;
        final (_, oidStart, oidEnd) = _derElement(der, extStart);
        if (oidEnd - oidStart != sanOid.length ||
            !List.generate(sanOid.length, (i) => der[oidStart + i] == sanOid[i]).every((same) => same)) {
          continue;
        }
        var (valueTag, valueStart, valueEnd) = _derElement(der, oidEnd);
        // The optional `critical` BOOLEAN.
        if (valueTag == 0x01) {
          (valueTag, valueStart, valueEnd) = _derElement(der, valueEnd);
        }
        final (_, namesStart, namesEnd) = _derElement(der, valueStart);
        final uris = <String>[];
        for (var n = namesStart; n < namesEnd;) {
          final (nameTag, nameStart, nameEnd) = _derElement(der, n);
          n = nameEnd;
          if (nameTag == 0x86) uris.add(utf8.decode(der.sublist(nameStart, nameEnd), allowMalformed: true));
        }
        return uris;
      }
    }
  } on RangeError {
    // A certificate mbedTLS parsed but this walk cannot: report no URI.
  }
  return const [];
}
