import 'dart:ffi';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../extensions.dart';
import '../third_party/open62541.g.dart' as raw;

/// One way a session can identify itself on an endpoint, from the
/// endpoint's `userIdentityTokens`: anonymous, a username and password, a
/// certificate, or a token issued elsewhere ([tokenType]), under the
/// [policyId] the server wants echoed in the identity token.
class UserTokenPolicy {
  const UserTokenPolicy({
    required this.policyId,
    required this.tokenType,
    this.issuedTokenType = '',
    this.issuerEndpointUrl = '',
    this.securityPolicyUri = '',
  });

  /// The server's id for this policy; it goes into the identity token.
  final String policyId;

  /// Anonymous, username, certificate or issued token.
  final UserTokenType tokenType;

  /// For an issued token: the kind of token (a URI).
  final String issuedTokenType;

  /// For an issued token: where to get one.
  final String issuerEndpointUrl;

  /// The security policy the identity token is encrypted with; empty when
  /// it is the endpoint's own.
  final String securityPolicyUri;

  @override
  String toString() => 'UserTokenPolicy($policyId: ${_tokenTypeName(tokenType)})';
}

/// One endpoint of a server as the GetEndpoints service describes it (see
/// `Client.getEndpoints`): where it is ([endpointUrl]), how the channel is
/// secured ([securityPolicyUri], [securityMode], [securityLevel]), how a
/// session may identify itself ([userIdentityTokens]), who the server says it
/// is ([applicationUri], [productUri], [applicationName]) and, the reason to
/// ask, the [serverCertificate] (DER) that a client puts in its `trustList`
/// to authenticate this server from then on.
class EndpointDescription {
  const EndpointDescription({
    required this.endpointUrl,
    required this.securityPolicyUri,
    required this.securityMode,
    required this.securityLevel,
    required this.serverCertificate,
    required this.applicationUri,
    required this.productUri,
    required this.applicationName,
    required this.transportProfileUri,
    required this.userIdentityTokens,
  });

  /// The URL to connect to for this endpoint, as the server names itself
  /// (its hostname, not necessarily the address discovery was run on).
  final String endpointUrl;

  /// `http://opcfoundation.org/UA/SecurityPolicy#None`, `#Basic256Sha256`,
  /// `#Aes128_Sha256_RsaOaep`, ...
  final String securityPolicyUri;

  /// None, Sign or SignAndEncrypt.
  final MessageSecurityMode securityMode;

  /// The server's ranking of its endpoints: higher is more secure.
  final int securityLevel;

  /// The server's application instance certificate, DER; empty when the
  /// server has none (a SecurityPolicy#None-only server). What goes into
  /// `trustList` to authenticate this server.
  final Uint8List serverCertificate;

  /// The server's ApplicationUri, which a certificate of its own also
  /// carries as a URI subject alternative name.
  final String applicationUri;

  /// The server's ProductUri.
  final String productUri;

  /// The text of the server's ApplicationName.
  final String applicationName;

  /// `http://opcfoundation.org/UA-Profile/Transport/uatcp-uasc-uabinary` for
  /// an opc.tcp endpoint.
  final String transportProfileUri;

  /// The identity tokens this endpoint accepts.
  final List<UserTokenPolicy> userIdentityTokens;

  /// The SHA-1 of [serverCertificate] as 40 uppercase hex digits, the
  /// thumbprint OPC UA tooling (UaExpert, a server's certificate manager)
  /// shows for a certificate, to compare with one obtained out of band
  /// before the certificate is trusted. Empty when there is no certificate.
  String get certificateThumbprint =>
      serverCertificate.isEmpty ? '' : sha1.convert(serverCertificate).toString().toUpperCase();

  @override
  String toString() {
    final certificate = serverCertificate.isEmpty ? 'no certificate' : 'certificate $certificateThumbprint';
    final tokens = userIdentityTokens.map((t) => _tokenTypeName(t.tokenType)).join(', ');
    return 'EndpointDescription($endpointUrl, ${_securityModeName(securityMode)}, '
        '${securityPolicyUri.split('#').last}, level $securityLevel, $certificate, tokens [$tokens])';
  }
}

String _securityModeName(MessageSecurityMode mode) => switch (mode) {
  MessageSecurityMode.UA_MESSAGESECURITYMODE_NONE => 'None',
  MessageSecurityMode.UA_MESSAGESECURITYMODE_SIGN => 'Sign',
  MessageSecurityMode.UA_MESSAGESECURITYMODE_SIGNANDENCRYPT => 'SignAndEncrypt',
  _ => 'Invalid',
};

String _tokenTypeName(UserTokenType type) => switch (type) {
  UserTokenType.UA_USERTOKENTYPE_ANONYMOUS => 'anonymous',
  UserTokenType.UA_USERTOKENTYPE_USERNAME => 'username',
  UserTokenType.UA_USERTOKENTYPE_CERTIFICATE => 'certificate',
  UserTokenType.UA_USERTOKENTYPE_ISSUEDTOKEN => 'issued token',
  _ => 'unknown',
};

/// A Dart copy of a native `UA_EndpointDescription`; the native one stays
/// the caller's to free.
EndpointDescription endpointDescriptionFromNative(raw.UA_EndpointDescription native) {
  final certificate = native.serverCertificate;
  return EndpointDescription(
    endpointUrl: native.endpointUrl.value,
    securityPolicyUri: native.securityPolicyUri.value,
    securityMode: native.securityMode,
    securityLevel: native.securityLevel,
    serverCertificate: certificate.length == 0
        ? Uint8List(0)
        : Uint8List.fromList(certificate.data.asTypedList(certificate.length)),
    applicationUri: native.server.applicationUri.value,
    productUri: native.server.productUri.value,
    applicationName: native.server.applicationName.text.value,
    transportProfileUri: native.transportProfileUri.value,
    userIdentityTokens: List.unmodifiable([
      for (var i = 0; i < native.userIdentityTokensSize; i++)
        UserTokenPolicy(
          policyId: native.userIdentityTokens[i].policyId.value,
          tokenType: native.userIdentityTokens[i].tokenType,
          issuedTokenType: native.userIdentityTokens[i].issuedTokenType.value,
          issuerEndpointUrl: native.userIdentityTokens[i].issuerEndpointUrl.value,
          securityPolicyUri: native.userIdentityTokens[i].securityPolicyUri.value,
        ),
    ]),
  );
}
