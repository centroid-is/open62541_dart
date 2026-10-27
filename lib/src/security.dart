import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io' show InternetAddress, InternetAddressType;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:logging/logging.dart';

import 'common.dart';
import 'extensions.dart' show MessageSecurityMode;
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

/// The kinds of user identity token a session can be activated with
/// (`UA_UserTokenType`; [value] is the wire value).
enum UserTokenType {
  anonymous(0),
  username(1),
  certificate(2),

  /// Listed by some servers; this package neither offers nor presents it.
  issuedToken(3);

  const UserTokenType(this.value);
  final int value;

  static UserTokenType fromValue(int value) => values.firstWhere(
    (t) => t.value == value,
    orElse: () => throw ArgumentError.value(value, 'value', 'not a UserTokenType'),
  );
}

/// An X.509 certificate, held as DER.
///
/// Both constructors parse the certificate with open62541's crypto backend
/// and throw an [ArgumentError] if it cannot: an entry open62541 fails to
/// parse in a trust list silently drops every entry after it, so a
/// [Certificate] is valid by construction.
final class Certificate {
  Certificate._(this.der, this.subject, this.notAfter);

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
      return Certificate._(
        copy.asUnmodifiableView(),
        subjectName,
        uaDateTimeToDateTime(expiry.value) ?? DateTime.fromMicrosecondsSinceEpoch(0, isUtc: true),
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

  /// The `URI:` SubjectAltNames, in certificate order (an OPC UA application
  /// certificate carries one, the ApplicationUri). Empty when there is none.
  late final List<String> applicationUris = List.unmodifiable(_uriSubjectAltNames(der));

  /// The OPC UA certificate thumbprint: SHA-1 over [der], uppercase hex.
  late final String sha1Thumbprint = sha1.convert(der).toString().toUpperCase();

  /// SHA-256 over [der], uppercase hex, for display.
  late final String sha256Thumbprint = sha256.convert(der).toString().toUpperCase();

  /// Whether a `URI:` SubjectAltName of this certificate is exactly [uri]:
  /// the ApplicationUri an OPC UA application using it must announce.
  bool hasApplicationUri(String uri) => using((arena) {
    final value = arena<raw.UA_String>();
    final bytes = utf8.encode(uri);
    value.ref.length = bytes.length;
    value.ref.data = arena<ffi.Uint8>(bytes.length)..asTypedList(bytes.length).setAll(0, bytes);
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
///   `['O=Centroid', 'CN=CentroidM a1@host']`, joined with commas.
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
    final subjects = uaStringArray(arena, subject);
    final sans = uaStringArray(arena, altNames);
    final params = keyValueMap(arena, {
      'key-size-bits': (raw.UA_TYPES_UINT16, keyBits),
      'expires-in-days': (raw.UA_TYPES_UINT16, days),
    });
    // A zeroed logger is a silent one; the status code is what we report.
    final logger = arena<raw.UA_Logger>();
    final key = arena<raw.UA_ByteString>();
    final cert = arena<raw.UA_ByteString>();
    final status = raw.UA_CreateCertificate(
      logger,
      subjects,
      subject.length,
      sans,
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
        Certificate.fromDer(Uint8List.fromList(cert.ref.data.asTypedList(cert.ref.length))),
        Uint8List.fromList(key.ref.data.asTypedList(key.ref.length)),
      );
    } finally {
      raw.UA_ByteString_clear(key);
      raw.UA_ByteString_clear(cert);
    }
  }, ua_calloc);
}

/// The DER form of [privateKey] (DER or PEM, PKCS#1 or PKCS#8), decrypted
/// with [password] if it is an encrypted PEM key.
///
/// A DER key is returned unchanged: open62541 decrypts PEM only, so an
/// encrypted key must be given as PEM. Throws a [UaStatusException]
/// (`BadSecurityChecksFailed`) for a wrong password or a key that does not
/// parse.
Uint8List decryptPrivateKey(Uint8List privateKey, {String? password}) => using((arena) {
  // open62541 reports bytes that are neither DER nor PEM as out of memory.
  if (privateKey.isEmpty || (privateKey[0] != 0x30 && !latin1.decode(privateKey).contains('-----BEGIN'))) {
    throw const UaStatusException(raw.UA_STATUSCODE_BADSECURITYCHECKSFAILED);
  }
  final passwordBytes = utf8.encode(password ?? '');
  final out = arena<raw.UA_ByteString>();
  final status = raw.UA_CertificateUtils_decryptPrivateKey(
    byteStringIn(arena, privateKey).ref,
    byteStringIn(arena, passwordBytes).ref,
    out,
  );
  try {
    if (status != raw.UA_STATUSCODE_GOOD) {
      throw UaStatusException(status);
    }
    return Uint8List.fromList(out.ref.data.asTypedList(out.ref.length));
  } finally {
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

/// The certificates and certificate revocation lists one side of an OPC UA
/// connection validates the other side's certificate against (Part 4 §6.1.3).
///
/// A peer certificate is accepted when it is in [trusted] (a self-signed
/// certificate is trusted by pinning it there), or when it chains through
/// [issuers] to a CA in [trusted]. CRLs (DER or PEM) are in [trustedCrls] for
/// the CAs in [trusted] and [issuerCrls] for those in [issuers]. Once any CRL
/// is given, every CA in a chain needs its CRL, else the certificate is
/// refused with `BadCertificateRevocationUnknown`.
///
/// An empty list trusts nobody. [TrustList.acceptAll] accepts every
/// certificate and must be asked for explicitly.
final class TrustList {
  const TrustList({
    this.trusted = const [],
    this.issuers = const [],
    this.trustedCrls = const [],
    this.issuerCrls = const [],
  }) : acceptsAll = false;

  /// Accepts every peer certificate without validation (open62541's
  /// `UA_CertificateGroup_AcceptAll`). Only for tests and lab setups.
  const TrustList.acceptAll()
    : trusted = const [],
      issuers = const [],
      trustedCrls = const [],
      issuerCrls = const [],
      acceptsAll = true;

  final List<Certificate> trusted;
  final List<Certificate> issuers;
  final List<Uint8List> trustedCrls;
  final List<Uint8List> issuerCrls;

  /// Whether this is [TrustList.acceptAll].
  final bool acceptsAll;
}

/// How a secured `Server` encrypts and whom it trusts (`Server(security:)`).
///
/// * [certificate] and [privateKey] (DER or PEM; an encrypted PEM key with
///   [privateKeyPassword]) are the server's application instance
///   certificate. The server's `applicationUri` must be the certificate's
///   URI SubjectAltName.
/// * [policies] and [modes] give the endpoints: one per policy and mode.
/// * [allowNone] adds a SecurityPolicy#None endpoint. Without it the None
///   policy still answers GetEndpoints and FindServers, so clients can
///   discover the secure endpoints, but opens no session.
/// * [applicationTrust] validates client application certificates (Open
///   SecureChannel and CreateSession). The empty default trusts nobody.
/// * [userTrust] validates X.509 user identity tokens. `null`, the default,
///   offers no certificate login.
/// * [allowUnencryptedPassword] lets a password travel unencrypted on a
///   None channel (open62541's `allowNonePolicyPassword`).
final class ServerSecurity {
  const ServerSecurity({
    required this.certificate,
    required this.privateKey,
    this.privateKeyPassword,
    this.policies = SecurityPolicy.secure,
    this.modes = const {
      MessageSecurityMode.UA_MESSAGESECURITYMODE_SIGN,
      MessageSecurityMode.UA_MESSAGESECURITYMODE_SIGNANDENCRYPT,
    },
    this.allowNone = false,
    this.applicationTrust = const TrustList(),
    this.userTrust,
    this.allowUnencryptedPassword = false,
  });

  final Certificate certificate;
  final Uint8List privateKey;
  final String? privateKeyPassword;
  final Set<SecurityPolicy> policies;
  final Set<MessageSecurityMode> modes;
  final bool allowNone;
  final TrustList applicationTrust;
  final TrustList? userTrust;
  final bool allowUnencryptedPassword;
}

final _log = Logger('open62541.security');

/// Throws an [ArgumentError] naming [name] if a CRL of [list] does not
/// parse: open62541's memory store stops loading at the first such entry.
void validateTrustList(TrustList list, String name) {
  if (list.acceptsAll) {
    _log.warning('$name accepts every certificate (TrustList.acceptAll)');
    return;
  }
  for (final crl in [...list.trustedCrls, ...list.issuerCrls]) {
    if (!_isCrl(crl)) {
      throw ArgumentError.value('${crl.length} bytes', name, 'contains a CRL that does not parse');
    }
  }
}

bool _isCrl(Uint8List bytes) => using((arena) {
  final data = byteStringIn(arena, bytes);
  // getSubjectName falls back to parsing a CRL when the bytes are no
  // certificate; getExpirationDate tells the two apart.
  if (raw.UA_CertificateUtils_getExpirationDate(data, arena<ffi.Int64>()) == raw.UA_STATUSCODE_GOOD) return false;
  final subject = arena<raw.UA_String>();
  final status = raw.UA_CertificateUtils_getSubjectName(data, subject);
  raw.UA_ByteString_clear(subject);
  return status == raw.UA_STATUSCODE_GOOD;
}, ua_calloc);

/// Runs [update] on a copy of the certificate group that [get] reads out of
/// a config struct and writes it back with [set]. The certificate group
/// plugins keep no pointer to the group struct itself, only to its context.
T _withCertificateGroup<T>(
  raw.UA_CertificateGroup Function() get,
  void Function(raw.UA_CertificateGroup) set,
  T Function(ffi.Pointer<raw.UA_CertificateGroup> group, Arena arena) update,
) => using((arena) {
  final group = arena<raw.UA_CertificateGroup>()..ref = get();
  try {
    return update(group, arena);
  } finally {
    set(group.ref);
  }
}, ua_calloc);

/// Replaces the certificate group in a config field with one validating
/// against [list] (open62541's memory store, or AcceptAll for
/// [TrustList.acceptAll]). [groupId] is the group's NS0 node, [logger] the
/// config's, which the group keeps.
int installTrustList(
  raw.UA_CertificateGroup Function() get,
  void Function(raw.UA_CertificateGroup) set,
  int groupId,
  TrustList list,
  ffi.Pointer<raw.UA_Logger> logger,
) => _withCertificateGroup(get, set, (group, arena) {
  if (list.acceptsAll) {
    raw.UA_CertificateGroup_AcceptAll(group);
    return raw.UA_STATUSCODE_GOOD;
  }
  ffi.Pointer<raw.UA_ByteString> array(List<List<int>> entries) {
    final out = arena<raw.UA_ByteString>(entries.isEmpty ? 1 : entries.length);
    for (var i = 0; i < entries.length; i++) {
      out[i] = byteStringIn(arena, entries[i]).ref;
    }
    return out;
  }

  final trust = arena<raw.UA_TrustListDataType>();
  trust.ref.specifiedLists = raw.UA_TrustListMasks.UA_TRUSTLISTMASKS_ALL.value;
  trust.ref.trustedCertificatesSize = list.trusted.length;
  trust.ref.trustedCertificates = array([for (final c in list.trusted) c.der]);
  trust.ref.issuerCertificatesSize = list.issuers.length;
  trust.ref.issuerCertificates = array([for (final c in list.issuers) c.der]);
  trust.ref.trustedCrlsSize = list.trustedCrls.length;
  trust.ref.trustedCrls = array(list.trustedCrls);
  trust.ref.issuerCrlsSize = list.issuerCrls.length;
  trust.ref.issuerCrls = array(list.issuerCrls);
  final id = arena<raw.UA_NodeId>()..ref = raw.UA_NODEID_NUMERIC(0, groupId);
  // The trust list is copied in; 0 lifts the 64 KiB cap on later additions,
  // and the rejected list keeps open62541's default of 100.
  final params = keyValueMap(arena, {
    'max-trust-listsize': (raw.UA_TYPES_UINT32, 0),
    'max-rejected-listsize': (raw.UA_TYPES_UINT32, 100),
  });
  return raw.UA_CertificateGroup_Memorystore(group, id, trust, logger, params);
});

/// Clears the certificate group in a config field and leaves it empty (no
/// `verifyCertificate`).
void clearCertificateGroup(raw.UA_CertificateGroup Function() get, void Function(raw.UA_CertificateGroup) set) =>
    _withCertificateGroup(get, set, (group, arena) {
      final clear = group.ref.clear;
      if (clear != ffi.nullptr) {
        clear.asFunction<void Function(ffi.Pointer<raw.UA_CertificateGroup>)>()(group);
      }
      group.ref = ffi.Struct.create<raw.UA_CertificateGroup>();
    });

/// The certificates [group] refused, oldest first (empty for a group
/// without a rejected list, such as AcceptAll). Entries that do not parse
/// as a certificate are left out.
List<Certificate> rejectedCertificates(raw.UA_CertificateGroup group) {
  final getRejectedList = group.getRejectedList;
  if (getRejectedList == ffi.nullptr) return const [];
  return using((arena) {
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
      final entry = list.value[i];
      try {
        result.add(Certificate.fromDer(Uint8List.fromList(entry.data.asTypedList(entry.length))));
      } on ArgumentError {
        continue;
      }
    }
    raw.UA_Array_delete(list.value.cast(), size.value, getTypeByIndex(raw.UA_TYPES_BYTESTRING));
    return result;
  }, ua_calloc);
}

/// A `UA_ByteString` in [arena] viewing a copy of [bytes].
ffi.Pointer<raw.UA_ByteString> byteStringIn(Arena arena, List<int> bytes) {
  final s = arena<raw.UA_ByteString>();
  s.ref.length = bytes.length;
  if (bytes.isNotEmpty) {
    s.ref.data = arena<ffi.Uint8>(bytes.length)..asTypedList(bytes.length).setAll(0, bytes);
  }
  return s;
}

/// A `UA_String` array in [arena].
ffi.Pointer<raw.UA_String> uaStringArray(Arena arena, List<String> values) {
  final array = arena<raw.UA_String>(values.length);
  for (var i = 0; i < values.length; i++) {
    final bytes = utf8.encode(values[i]);
    array[i].length = bytes.length;
    array[i].data = arena<ffi.Uint8>(bytes.length)..asTypedList(bytes.length).setAll(0, bytes);
  }
  return array;
}

/// open62541's `UA_KeyValuePair`, which the bindings leave opaque.
final class UaKeyValuePair extends ffi.Struct {
  external raw.UA_QualifiedName key;
  external raw.UA_Variant value;
}

/// A `UA_KeyValueMap` in [arena] of unsigned integer scalars, each given as
/// `(UA_TYPES index, value)`. The map only lends its storage: open62541 reads
/// these plugin parameters during the call it is passed to.
ffi.Pointer<raw.UA_KeyValueMap> keyValueMap(Arena arena, Map<String, (int, int)> entries) {
  final pairs = arena<UaKeyValuePair>(entries.length);
  var i = 0;
  for (final MapEntry(key: name, value: (typeIndex, value)) in entries.entries) {
    final pair = pairs[i++];
    final nameBytes = utf8.encode(name);
    pair.key.namespaceIndex = 0;
    pair.key.name.length = nameBytes.length;
    pair.key.name.data = arena<ffi.Uint8>(nameBytes.length)..asTypedList(nameBytes.length).setAll(0, nameBytes);
    final ffi.Pointer<ffi.Void> data;
    switch (typeIndex) {
      case raw.UA_TYPES_UINT16:
        data = (arena<ffi.Uint16>()..value = value).cast();
      case raw.UA_TYPES_UINT32:
        data = (arena<ffi.Uint32>()..value = value).cast();
      default:
        throw ArgumentError.value(typeIndex, 'typeIndex', 'unsupported parameter type');
    }
    pair.value.type = getTypeByIndex(typeIndex);
    pair.value.storageType = raw.UA_VariantStorageType.UA_VARIANT_DATA_NODELETE;
    pair.value.data = data;
  }
  final map = arena<raw.UA_KeyValueMap>();
  map.ref.mapSize = entries.length;
  map.ref.map = pairs.cast();
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
