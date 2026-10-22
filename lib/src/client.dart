import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'package:open62541/src/types/errors.dart';
import 'client_api.dart';
import 'common.dart';
import 'dynamic_value.dart';
import 'extensions.dart';
import 'node_id.dart';
import 'third_party/open62541.g.dart' as raw;
import 'types/create_type.dart';
import 'types/endpoint_description.dart';
import 'types/native_decode.dart';
import 'types/opcua_serializer.dart';
import 'ua_allocation.dart';

// Safe error log for the worker isolate. On a detached GUI launch (release)
// BOTH stdout and stderr have invalid handles, and a write to either throws
// asynchronously ('handle is invalid') -> with Isolate.spawn's default
// errorsAreFatal that uncaught throw KILLS the worker, taking a whole OPC UA
// server offline. So never touch the std streams here: append to the app's log
// file if one is configured, else drop the line.
final String? _logFilePath = Platform.environment['OPEN62541_LOG_FILE'];
void _safeErr(Object? m) {
  final p = _logFilePath;
  if (p == null || p.isEmpty) return;
  try {
    File(p).writeAsStringSync('$m\n', mode: FileMode.append, flush: true);
  } catch (_) {}
}

typedef NodeClass = raw.UA_NodeClass;

typedef BrowseResultMask = raw.UA_BrowseResultMask;

class BrowseResultItem {
  final NodeId referenceTypeId;
  final bool isForward;
  final NodeId nodeId;
  final String browseName;
  final String displayName;
  final NodeClass nodeClass;
  final NodeId? typeDefinition;

  const BrowseResultItem({
    required this.referenceTypeId,
    required this.isForward,
    required this.nodeId,
    required this.browseName,
    required this.displayName,
    required this.nodeClass,
    this.typeDefinition,
  });

  @override
  String toString() {
    return 'BrowseResultItem(displayName: $displayName, nodeId: $nodeId, nodeClass: $nodeClass)';
  }
}

class BrowseTreeItem {
  final BrowseResultItem item;
  final int depth;
  final NodeId parentNodeId;

  const BrowseTreeItem({required this.item, required this.depth, required this.parentNodeId});

  NodeId get nodeId => item.nodeId;
  String get displayName => item.displayName;
  String get browseName => item.browseName;
  NodeClass get nodeClass => item.nodeClass;

  @override
  String toString() {
    return '${"  " * depth}${item.displayName} (${item.nodeId}) [${item.nodeClass}]';
  }
}

/// The packed `UA_DataValue` flag byte. ffigen does not emit the C bitfield
/// members individually: the generated struct ends with a single
/// `@UA_Byte() external int substitute`, which IS their storage unit. Bit
/// positions follow the declaration order in `include/open62541/types.h`
/// (hasValue, hasStatus, hasSourceTimestamp, hasServerTimestamp,
/// hasSourcePicoseconds, hasServerPicoseconds); measured against the
/// in-process server and pinned by test/monitor_data_value_test.dart.
const int _hasValueFlag = 0x01;
const int _hasStatusFlag = 0x02;
const int _hasSourceTimestampFlag = 0x04;
const int _hasServerTimestampFlag = 0x08;

/// Severity bits (the top two of a status code): 00 Good, 01 Uncertain, 10 Bad.
bool _isGoodSeverity(int statusCode) => (statusCode >> 30) == 0x0;

/// The status and timestamps of a node's latest Value notification, kept next
/// to its [DynamicValue] by the monitored-item machinery and turned into a
/// [DataValue] on emission.
class _SampleQuality {
  const _SampleQuality({required this.statusCode, this.sourceTimestamp, this.serverTimestamp});

  /// No Value notification yet (the node's Value attribute is not monitored,
  /// or its value was backfilled by a read): the status an omitted status
  /// means, Good, and no timestamps.
  const _SampleQuality.unknown() : this(statusCode: raw.UA_STATUSCODE_GOOD);

  final int statusCode;
  final DateTime? sourceTimestamp;
  final DateTime? serverTimestamp;

  DataValue toDataValue(DynamicValue value) => DataValue(
    value: value,
    statusCode: statusCode,
    sourceTimestamp: sourceTimestamp,
    serverTimestamp: serverTimestamp,
  );
}

/// A full OPC UA read result: the decoded [value] together with the
/// operation's [statusCode] and the source/server timestamps.
///
/// Returned by [Client.readValue] and, per sample, by
/// [DataValueMonitoringApi.monitorDataValue] /
/// [DataValueMonitoringApi.monitoredDataValues]. Unlike [Client.read] (which
/// throws on any non-Good status), a [DataValue] surfaces the quality: per OPC
/// UA a Bad status may still carry a value — e.g. a proxy serving the
/// last-known value with `Bad_NoCommunication` while its backing device is
/// down.
class DataValue {
  const DataValue({required this.value, required this.statusCode, this.sourceTimestamp, this.serverTimestamp});

  /// The decoded value. An empty [DynamicValue] when the server sent none
  /// (common for Bad statuses without a last-known value).
  final DynamicValue value;

  /// The operation-level OPC UA status code (`UA_STATUSCODE_GOOD` when the
  /// server omitted an explicit status).
  final int statusCode;

  /// When the underlying value was produced/sampled at the source, or `null`
  /// if the server did not return one.
  final DateTime? sourceTimestamp;

  /// When the server processed the read, or `null` if not returned.
  final DateTime? serverTimestamp;

  /// Severity bits (top two bits of the status code): 00 Good, 01 Uncertain,
  /// 10 Bad.
  bool get isGood => (statusCode >> 30) == 0x0;
  bool get isUncertain => (statusCode >> 30) == 0x1;
  bool get isBad => (statusCode >> 30) == 0x2;

  @override
  String toString() =>
      'DataValue(status: 0x${statusCode.toRadixString(16).padLeft(8, '0')}, '
      'sourceTimestamp: $sourceTimestamp, serverTimestamp: $serverTimestamp, value: ${value.value})';
}

class ClientState {
  SecureChannelState channelState;
  SessionState sessionState;
  int recoveryStatus;
  ClientState({required this.channelState, required this.sessionState, required this.recoveryStatus});

  @override
  String toString() {
    return 'ClientState(channelState: $channelState, sessionState: $sessionState, recoveryStatus: $recoveryStatus)';
  }
}

class ClientConfig {
  ClientConfig(this._clientConfig) {
    // Intercept callbacks
    _state =
        ffi.NativeCallable<
          ffi.Void Function(
            ffi.Pointer<raw.UA_Client> client,
            ffi.UnsignedInt channelState,
            ffi.UnsignedInt sessionState,
            raw.UA_StatusCode connectStatus,
          )
        >.isolateLocal(
          (ffi.Pointer<raw.UA_Client> client, int channelState, int sessionState, int recoveryStatus) =>
              _stateStream.add(
                ClientState(
                  channelState: raw.UA_SecureChannelState.fromValue(channelState),
                  sessionState: raw.UA_SessionState.fromValue(sessionState),
                  recoveryStatus: recoveryStatus,
                ),
              ),
        );
    _clientConfig.ref.stateCallback = _state.nativeFunction;
    _subscriptionInactivityCallback =
        ffi.NativeCallable<
          ffi.Void Function(ffi.Pointer<raw.UA_Client>, raw.UA_UInt32, ffi.Pointer<ffi.Void>)
        >.isolateLocal(_subscriptionInactivityC);
    _clientConfig.ref.subscriptionInactivityCallback = _subscriptionInactivityCallback.nativeFunction;
    _inactivityCallback = ffi.NativeCallable<ffi.Void Function(ffi.Pointer<raw.UA_Client>)>.isolateLocal(
      _inactivityCallbackC,
    );
    _clientConfig.ref.inactivityCallback = _inactivityCallback.nativeFunction;
  }

  void _inactivityCallbackC(ffi.Pointer<raw.UA_Client> client) {
    _inactivity.add(null);
  }

  void _subscriptionInactivityC(ffi.Pointer<raw.UA_Client> client, int subId, ffi.Pointer<ffi.Void> subContext) {
    _subscriptionInactivity.add(subId);
  }

  Stream<ClientState> get stateStream => _stateStream.stream;
  Stream<int> get subscriptionInactivityStream => _subscriptionInactivity.stream;
  Stream<int> get subscriptionDeletedStream => _subscriptionDeleted.stream;
  Stream<void> get inactivityStream => _inactivity.stream;

  raw.UA_MessageSecurityMode get securityMode => _clientConfig.ref.securityMode;
  set securityMode(raw.UA_MessageSecurityMode mode) {
    _clientConfig.ref.securityModeAsInt = mode.value;
  }

  String get securityPolicyUri => _clientConfig.ref.securityPolicyUri.value;
  set securityPolicyUri(String uri) {
    _clientConfig.ref.securityPolicyUri.set(uri);
  }

  /// The `applicationUri` of the ApplicationDescription this client presents
  /// in CreateSession. Set it **before** connecting. On the server it
  /// surfaces as `MethodSessionInfo.applicationUri`. Note: when connecting
  /// with a certificate, open62541 overwrites this with the URI embedded in
  /// the certificate.
  String get applicationUri => _clientConfig.ref.clientDescription.applicationUri.value;
  set applicationUri(String uri) {
    _clientConfig.ref.clientDescription.applicationUri.set(uri);
  }

  /// The text of the `applicationName` LocalizedText this client presents in
  /// CreateSession (the locale is left as configured, "en" by default). Set
  /// it **before** connecting. On the server it surfaces as
  /// `MethodSessionInfo.applicationName`.
  String get applicationName => _clientConfig.ref.clientDescription.applicationName.text.value;
  set applicationName(String name) {
    _clientConfig.ref.clientDescription.applicationName.text.set(name);
  }

  /// The client-defined session name sent in CreateSession. Set it **before**
  /// connecting. On the server it surfaces as
  /// `MethodSessionInfo.sessionName`. When unset open62541 generates one from
  /// the application URI.
  String get sessionName => _clientConfig.ref.sessionName.value;
  set sessionName(String name) {
    _clientConfig.ref.sessionName.set(name);
  }

  int get outstandingPublishRequests => _clientConfig.ref.outStandingPublishRequests;

  Future<void> close() async {
    await _stateStream.close();
    await _subscriptionInactivity.close();
    await _subscriptionDeleted.close();
    await _inactivity.close();

    _state.close();
    _subscriptionInactivityCallback.close();
    _inactivityCallback.close();
  }

  // Private interface
  final ffi.Pointer<raw.UA_ClientConfig> _clientConfig;
  final StreamController<ClientState> _stateStream = StreamController<ClientState>.broadcast();
  final StreamController<int> _subscriptionInactivity = StreamController<int>.broadcast();
  final StreamController<int> _subscriptionDeleted = StreamController<int>.broadcast();
  final StreamController<void> _inactivity = StreamController<void>.broadcast();
  late ffi.NativeCallable<
    ffi.Void Function(
      ffi.Pointer<raw.UA_Client> client,
      ffi.UnsignedInt channelState,
      ffi.UnsignedInt sessionState,
      raw.UA_StatusCode connectStatus,
    )
  >
  _state;
  late ffi.NativeCallable<ffi.Void Function(ffi.Pointer<raw.UA_Client>, raw.UA_UInt32, ffi.Pointer<ffi.Void>)>
  _subscriptionInactivityCallback;
  late ffi.NativeCallable<ffi.Void Function(ffi.Pointer<raw.UA_Client>)> _inactivityCallback;
}

typedef ReadAttributeParam = Map<NodeId, List<AttributeId>>;

/// The Bad status of the one BrowseResult of a Browse. Surfaces from
/// [Client.browse] with the message it always had; typed so the client's own
/// lookups can tell "no such node" from a failed service.
class _BrowseResultError implements Exception {
  const _BrowseResultError(this.statusCode);
  final int statusCode;
  @override
  String toString() => 'Browse result error: ${statusCodeToString(statusCode)}';
}

/// Checks that the certificate arguments of a [Client] make sense together
/// and throws an [ArgumentError] when they do not. `ClientIsolate.create`
/// forwards the same arguments and runs this check first, on the calling
/// isolate, so a bad combination is an exception there and not an error lost
/// in a worker that never got a client.
///
/// The rules:
///  * [certificate] and [privateKey] come together.
///  * The lists and [acceptAllCertificates] need a certificate: the server
///    certificate is only verified on a channel with a security policy, and
///    a client without a certificate offers SecurityPolicy#None only.
///  * With a certificate, either a non-empty [trustList] or
///    `acceptAllCertificates: true`; not both, and not neither. open62541's
///    `UA_ClientConfig_setDefaultEncryption` treats an empty trust list as
///    "leave the previous verification in place", which is accept-all with a
///    warning in the log; refusing it here makes accepting any server an
///    explicit choice. An [issuerList] or [revocationList] alone is refused
///    for the same reason: issuer certificates only complete a chain, they
///    cannot anchor trust.
void checkClientCertificateArguments({
  required Uint8List? certificate,
  required Uint8List? privateKey,
  required List<Uint8List>? trustList,
  required List<Uint8List>? issuerList,
  required List<Uint8List>? revocationList,
  required bool acceptAllCertificates,
}) {
  if ((certificate == null) != (privateKey == null)) {
    throw ArgumentError('certificate and privateKey come together; got only one of them');
  }
  final hasLists = trustList != null || issuerList != null || revocationList != null;
  if (certificate == null) {
    if (hasLists || acceptAllCertificates) {
      throw ArgumentError(
        'trustList, issuerList, revocationList and acceptAllCertificates need a certificate and privateKey: '
        'without them the client offers SecurityPolicy#None only and never sees a server certificate to verify',
      );
    }
    return;
  }
  if (acceptAllCertificates) {
    if (hasLists) {
      throw ArgumentError(
        'acceptAllCertificates: true and a trustList/issuerList/revocationList contradict each other',
      );
    }
    return;
  }
  if (trustList == null || trustList.isEmpty) {
    throw ArgumentError(
      'a certificate needs a non-empty trustList (the server certificates, or the CA certificates that issued '
      'them, DER), or acceptAllCertificates: true to skip server authentication. open62541 treats an empty '
      'trust list as "accept every certificate", so an empty one is refused rather than silently accepting any server',
    );
  }
}

/// A `UA_ByteString` in [arena] holding a copy of [bytes].
ffi.Pointer<raw.UA_ByteString> _byteString(Arena arena, Uint8List bytes) {
  final string = arena<raw.UA_ByteString>();
  string.ref.length = bytes.length;
  string.ref.data = arena<ffi.Uint8>(bytes.length);
  string.ref.data.asTypedList(bytes.length).setAll(0, bytes);
  return string;
}

/// An array of `UA_ByteString` in [arena], one per element of [list], each
/// holding a copy. `nullptr` for an empty list.
ffi.Pointer<raw.UA_ByteString> _byteStrings(Arena arena, List<Uint8List> list) {
  if (list.isEmpty) return ffi.nullptr;
  final array = arena<raw.UA_ByteString>(list.length);
  for (var i = 0; i < list.length; i++) {
    final bytes = list[i];
    array[i].length = bytes.length;
    array[i].data = arena<ffi.Uint8>(bytes.length);
    array[i].data.asTypedList(bytes.length).setAll(0, bytes);
  }
  return array;
}

/// An OPC UA client over open62541, pumped by the caller ([runIterate] or
/// [keepConnected]).
///
/// ## Security
///
/// Without a [certificate] the client offers SecurityPolicy#None: nothing on
/// the wire is signed or encrypted, and a [username]/[password] only travels
/// if [allowUnencryptedPassword] is set, in clear text then.
///
/// With a [certificate] and [privateKey] (DER) and a [securityMode] of
/// `Sign` or `SignAndEncrypt` the channel is signed or encrypted with a
/// policy the server offers (Basic256Sha256, Aes128Sha256RsaOaep, ...).
/// Encryption alone does not say *who* the peer is: the server's certificate
/// must be verified, or anyone on the path can present their own certificate
/// and read everything. Pass the certificates to trust in [trustList] (DER:
/// the server's own certificate, or the CA certificate that issued it), and
/// optionally [issuerList] (intermediate CA certificates, which only complete
/// a chain and are not trusted by themselves) and [revocationList] (CRLs,
/// DER). open62541 verifies the server certificate against them before the
/// channel opens and refuses a server that does not match: [connect] throws a
/// [UaStatusException] with the certificate status (`BadCertificateUntrusted`
/// for a certificate that is in no list, `BadCertificateTimeInvalid`,
/// `BadCertificateRevoked`, ...).
///
/// [acceptAllCertificates] skips that verification: any certificate opens
/// the channel. The session is still encrypted, which stops passive
/// eavesdropping, but the server is not authenticated, so an active attacker
/// (a machine in the middle, a spoofed endpoint) goes unnoticed. It is
/// opt-in: a certificate without a [trustList] and without
/// `acceptAllCertificates: true` is an [ArgumentError], see
/// [checkClientCertificateArguments].
///
/// The endpoint hostname is not checked against the server certificate.
///
/// ## Discovery, and trust on first use
///
/// A [trustList] needs the server certificate before the first secure
/// connection. [getEndpoints] gets it from the server itself: the
/// GetEndpoints service runs over a SecurityPolicy#None channel without a
/// session, so it needs no certificate and no trust list, and every
/// [EndpointDescription] it returns carries the [EndpointDescription.serverCertificate]
/// (DER) with the policy and mode of that endpoint. Discovery authenticates
/// nothing: a machine in the middle at that moment hands over its own
/// certificate, and trusting it would make every later "encrypted" session
/// its to read. So before the certificate is trusted, compare its
/// [EndpointDescription.certificateThumbprint] (SHA-1, what the server's
/// own certificate manager shows) with one obtained out of band, from the
/// server's operator. Then persist the DER and pass it as [trustList] from
/// then on; a server whose certificate changes is refused with
/// `BadCertificateUntrusted`, which is the point.
///
/// ```dart
/// final endpoints = await Client.getEndpoints('opc.tcp://plc:4840');
/// final endpoint = endpoints.firstWhere(
///   (e) => e.securityMode == MessageSecurityMode.UA_MESSAGESECURITYMODE_SIGNANDENCRYPT,
/// );
/// print('server certificate ${endpoint.certificateThumbprint}'); // confirm out of band
/// await File('server_cert.der').writeAsBytes(endpoint.serverCertificate);
/// // Next time:
/// final client = Client(
///   securityMode: MessageSecurityMode.UA_MESSAGESECURITYMODE_SIGNANDENCRYPT,
///   certificate: clientCertificate,
///   privateKey: clientKey,
///   trustList: [await File('server_cert.der').readAsBytes()],
/// );
/// ```
class Client implements ClientApi, DataValueMonitoringApi {
  /// See the class documentation for the certificate arguments; they are
  /// checked by [checkClientCertificateArguments] before anything is
  /// allocated.
  ///
  /// [allowUnencryptedPassword]: open62541 refuses to send a password over
  /// SecurityPolicy#None, where it travels in clear text, so username
  /// authentication over None fails silently at the server. This opt-in
  /// sends it anyway. Only for a network trusted end to end (a lab, a
  /// machine network behind its own firewall); anywhere else use a
  /// certificate with `SignAndEncrypt` and a [trustList].
  ///
  /// [schemaCacheSize] caps the DataType definitions the client keeps for
  /// decoding (see [defs]).
  Client({
    Duration? secureChannelLifeTime,
    Duration? requestedSessionTimeout,
    String? username,
    String? password,
    MessageSecurityMode? securityMode,
    Uint8List? certificate,
    Uint8List? privateKey,
    List<Uint8List>? trustList,
    List<Uint8List>? issuerList,
    List<Uint8List>? revocationList,
    bool acceptAllCertificates = false,
    LogLevel? logLevel,
    Duration connectivityCheckInterval = const Duration(seconds: 1),
    bool allowUnencryptedPassword = false,
    this.schemaCacheSize = defaultSchemaCacheSize,
  }) {
    checkClientCertificateArguments(
      certificate: certificate,
      privateKey: privateKey,
      trustList: trustList,
      issuerList: issuerList,
      revocationList: revocationList,
      acceptAllCertificates: acceptAllCertificates,
    );
    final config = ua_calloc<raw.UA_ClientConfig>();

    if (logLevel != null) {
      config.ref.logging = raw.UA_Log_Stdout_new(logLevel);
    }

    // The event loop logger is set to the config logger if defined
    // No need to modify the eventloop logger.
    raw.UA_ClientConfig_setDefault(config);

    if (secureChannelLifeTime != null) {
      config.ref.secureChannelLifeTime = secureChannelLifeTime.inMilliseconds;
    }
    if (requestedSessionTimeout != null) {
      config.ref.requestedSessionTimeout = requestedSessionTimeout.inMilliseconds;
    }

    if (securityMode != null) {
      config.ref.securityModeAsInt = securityMode.value;
    }

    if (certificate != null && privateKey != null) {
      // Everything here is scratch for the calls: open62541 keeps its own
      // copies of the certificate and key (in each security policy, the key
      // decrypted to DER) and of the lists (UA_Array_copy into a
      // UA_TrustListDataType that UA_CertificateGroup_Memorystore copies
      // again into its store, after which the first copy is cleared;
      // addToTrustList appends copies the same way).
      using((arena) {
        final rawCertificate = _byteString(arena, certificate);
        final rawPrivateKey = _byteString(arena, privateKey);
        final trust = trustList ?? const <Uint8List>[];
        final revocation = revocationList ?? const <Uint8List>[];
        raw.UA_ClientConfig_setDefaultEncryption(
          config,
          rawCertificate.ref,
          rawPrivateKey.ref,
          _byteStrings(arena, trust),
          trust.length,
          _byteStrings(arena, revocation),
          revocation.length,
        );

        // Dart FFI cannot take the address of the UA_CertificateGroup nested
        // in the config, so the plugin calls below get a copy of the struct.
        // They only read it (the store is behind `context`, which the copy
        // shares) or set its function pointers, so the copy goes back.
        final group = arena<raw.UA_CertificateGroup>();
        group.ref = config.ref.certificateVerification;
        if (acceptAllCertificates) {
          raw.UA_CertificateGroup_AcceptAll(group);
        } else if (issuerList != null && issuerList.isNotEmpty) {
          // setDefaultEncryption takes no issuer list; the memory store it
          // installed (for a non-empty trust list, which
          // checkClientCertificateArguments guarantees here) does.
          final issuers = arena<raw.UA_TrustListDataType>();
          issuers.ref.specifiedLists = raw.UA_TrustListMasks.UA_TRUSTLISTMASKS_ISSUERCERTIFICATES.value;
          issuers.ref.issuerCertificates = _byteStrings(arena, issuerList);
          issuers.ref.issuerCertificatesSize = issuerList.length;
          final addToTrustList = group.ref.addToTrustList
              .asFunction<int Function(ffi.Pointer<raw.UA_CertificateGroup>, ffi.Pointer<raw.UA_TrustListDataType>)>();
          final status = addToTrustList(group, issuers);
          if (status != raw.UA_STATUSCODE_GOOD) {
            throw UaStatusException(status);
          }
        }
        config.ref.certificateVerification = group.ref;
      }, ua_calloc);
    }

    if (username != null) {
      // open62541 copies both into the identity token (UA_STRING_ALLOC), so
      // the C strings are scratch for the call.
      using((arena) {
        raw.UA_ClientConfig_setAuthenticationUsername(
          config,
          username.toNativeUtf8(allocator: arena).cast(),
          password != null ? password.toNativeUtf8(allocator: arena).cast() : ffi.nullptr,
        );
      }, ua_calloc);
      // open62541 drops the plaintext-password UserTokenPolicy on an
      // unencrypted (SecurityPolicy#None) channel, so username auth silently
      // fails there unless this is enabled. Many PLC lab setups (and our
      // emulator) use username/password over None, so allow it opt-in.
      if (allowUnencryptedPassword) {
        config.ref.allowNonePolicyPassword = true;
      }
    }

    config.ref.connectivityCheckInterval = connectivityCheckInterval.inMilliseconds;
    _client = raw.UA_Client_newWithConfig(config);
    // UA_Client_newWithConfig *copies* the config struct into the client
    // (`client->config = *config`), so wrap the client's live copy — writes
    // through [ClientConfig]'s setters (and its callback registrations) must
    // land in the config the client actually reads, not in the stale
    // temporary. The temporary only carried pointers now owned by the
    // client's copy, so free just the struct itself.
    _clientConfig = ClientConfig(raw.UA_Client_getConfig(_client));
    ua_calloc.free(config);
  }

  ClientConfig get config => _clientConfig;

  /// The endpoints the server at [endpointUrl] offers, from its GetEndpoints
  /// service: for each, the security policy and mode, the identity tokens
  /// it accepts, who the server says it is, and its certificate (DER), which
  /// is how a client gets the certificate for its [trustList] (see the
  /// class documentation: trust on first use, with the thumbprint confirmed
  /// out of band, because discovery authenticates nothing).
  ///
  /// Needs no certificate and no trust list: the service runs over a
  /// SecurityPolicy#None channel without a session. Keeps nothing: a native
  /// client of its own, made for the call and deleted after it, on an
  /// isolate of its own ([Isolate.run]), because open62541's
  /// `UA_Client_getEndpoints` drives its own event loop and blocks until the
  /// answer, so the calling isolate, and whatever it pumps, keeps running
  /// meanwhile. The same static is on `ClientIsolate`.
  ///
  /// [timeout] bounds each step (opening the channel, the service call):
  /// a host that does not answer is a [TimeoutException]; a refused
  /// connection, a URL that is no endpoint URL or a Bad service result is a
  /// [UaStatusException] with open62541's status. [logLevel] is the
  /// temporary client's; the default keeps a failed attempt quiet below a
  /// warning.
  static Future<List<EndpointDescription>> getEndpoints(
    String endpointUrl, {
    Duration timeout = const Duration(seconds: 10),
    LogLevel logLevel = LogLevel.UA_LOGLEVEL_WARNING,
  }) async {
    final (status, endpoints) = await Isolate.run(
      () => _discoverEndpoints(endpointUrl, timeout, logLevel),
      debugName: 'open62541 GetEndpoints',
    );
    if (status == raw.UA_STATUSCODE_BADTIMEOUT) {
      throw TimeoutException('GetEndpoints on $endpointUrl: no answer within $timeout', timeout);
    }
    if (status != raw.UA_STATUSCODE_GOOD) {
      throw UaStatusException(status);
    }
    return endpoints;
  }

  /// [getEndpoints]'s native half, on the worker isolate: a default client
  /// with [timeout] as its response timeout, `UA_Client_getEndpoints`
  /// (connect without a session, GetEndpoints, disconnect), the answer
  /// copied to Dart, and everything native freed before it returns. The
  /// status comes back as a value; the caller throws on it.
  static (int, List<EndpointDescription>) _discoverEndpoints(String url, Duration timeout, LogLevel logLevel) {
    final config = ua_calloc<raw.UA_ClientConfig>();
    config.ref.logging = raw.UA_Log_Stdout_new(logLevel);
    raw.UA_ClientConfig_setDefault(config);
    // Bounds the channel open and the service call each (0 would be no
    // timeout at all).
    config.ref.timeout = timeout.inMilliseconds;
    final client = raw.UA_Client_newWithConfig(config);
    // The client holds a copy of the struct; the struct itself is ours.
    ua_calloc.free(config);
    try {
      return using((arena) {
        final size = arena<ffi.Size>();
        final array = arena<ffi.Pointer<raw.UA_EndpointDescription>>();
        // The URL is copied into the client config; the C string is scratch.
        final status = raw.UA_Client_getEndpoints(client, url.toNativeUtf8(allocator: arena).cast(), size, array);
        if (status != raw.UA_STATUSCODE_GOOD) {
          // Nothing was handed out: the out parameters are untouched.
          return (status, const <EndpointDescription>[]);
        }
        try {
          return (status, [for (var i = 0; i < size.value; i++) endpointDescriptionFromNative(array.value[i])]);
        } finally {
          // The array is open62541's allocation: cleared and freed as one.
          raw.UA_Array_delete(array.value.cast(), size.value, getTypeByIndex(raw.UA_TYPES_ENDPOINTDESCRIPTION));
        }
      }, ua_calloc);
    } finally {
      raw.UA_Client_delete(client);
    }
  }

  @override
  Future<void> awaitConnect() async {
    if (state.sessionState == raw.UA_SessionState.UA_SESSIONSTATE_ACTIVATED) {
      return;
    }
    await config.stateStream.firstWhere((state) => state.sessionState == raw.UA_SessionState.UA_SESSIONSTATE_ACTIVATED);
  }

  /// Connects to [url] and completes once the session is activated; the
  /// caller pumps ([runIterate]) meanwhile.
  ///
  /// [timeout] bounds the whole handshake (default 30 s, `null` waits as long
  /// as it takes): a peer that accepts the connection and never answers, or a
  /// server that never activates the session, is a [TimeoutException]. The
  /// attempt is then abandoned (the client disconnects), so [delete] and a
  /// later [connect] work. A handshake that fails instead is a
  /// [UaStatusException] with open62541's status.
  @override
  Future<void> connect(String url, {Duration? timeout = const Duration(seconds: 30)}) async {
    final instantReturn = _issueConnect(url);
    if (instantReturn != raw.UA_STATUSCODE_GOOD) {
      throw 'Failed to connect: ${statusCodeToString(instantReturn)}';
    }
    if (timeout == null) return _awaitHandshake();
    await _awaitHandshake().timeout(
      timeout,
      onTimeout: () {
        if (_client != ffi.nullptr) raw.UA_Client_disconnect(_client);
        throw TimeoutException('connect to $url: no activated session within $timeout', timeout);
      },
    );
  }

  /// Completes when the session is activated, or throws a [UaStatusException]
  /// with open62541's connect status when the handshake fails instead: a
  /// server certificate the trust list rejects (`BadCertificateUntrusted`),
  /// no endpoint for the security mode, a refused identity token, ...
  /// open62541 stops its connect state machine on a bad connect status and
  /// only another `connect()` restarts it, so once the status is bad there
  /// is nothing left to wait for. [awaitConnect] keeps waiting for an
  /// activation on purpose: under [keepConnected] a bad status is what the
  /// supervisor recovers from, and a waiter there wants the recovery.
  Future<void> _awaitHandshake() async {
    bool settled(ClientState s) =>
        s.sessionState == raw.UA_SessionState.UA_SESSIONSTATE_ACTIVATED || s.recoveryStatus != raw.UA_STATUSCODE_GOOD;
    // The connect call ran the first step of the handshake synchronously
    // and its state events are gone: start from the state as it is now.
    var snapshot = state;
    if (!settled(snapshot)) {
      snapshot = await config.stateStream.firstWhere(settled);
    }
    if (snapshot.sessionState != raw.UA_SessionState.UA_SESSIONSTATE_ACTIVATED) {
      throw UaStatusException(snapshot.recoveryStatus);
    }
  }

  /// Issues a (re)connect to [url] without awaiting session activation.
  ///
  /// This calls `UA_Client_connectAsync`, which restarts open62541's internal
  /// connect state machine and — crucially — resets `connectStatus` back to
  /// GOOD. After an unexpected drop open62541 makes only a single reconnect
  /// attempt; if the peer is briefly unreachable that attempt fails, leaves
  /// `connectStatus` bad, and the state machine then bails permanently. Only a
  /// fresh connect call clears that latch, which is what the auto-reconnect
  /// supervisor relies on. Returns the immediate status code.
  int _issueConnect(String url) {
    if (_client == ffi.nullptr) {
      return raw.UA_STATUSCODE_BADSERVERNOTCONNECTED;
    }
    // open62541 copies the URL into the client config (UA_STRING_ALLOC), so the
    // C string is scratch for the call.
    return using((arena) => raw.UA_Client_connectAsync(_client, url.toNativeUtf8(allocator: arena).cast()), ua_calloc);
  }

  /// Whether an auto-reconnect supervisor is currently running (see
  /// [keepConnected]).
  bool get isKeepingConnected => _keepConnected;

  /// Fires once each time the session returns to ACTIVATED after having left it
  /// (i.e. after a recovered drop). Does not fire for the very first connect.
  ///
  /// open62541 clears all client-side subscriptions on a drop, so a monitored
  /// item cannot be silently resumed — after reconnect the old subscription is
  /// gone. Listen here (or to [stateStream]) to re-create subscriptions and
  /// monitored items once the client is back.
  Stream<void> get reconnectStream => _reconnectController.stream;

  /// Opt-in auto-reconnect. Keeps this [Client] connected to [url] across
  /// server crashes/restarts and transient network partitions without the
  /// caller hand-rolling a pump-and-reconnect loop.
  ///
  /// It does three things a plain `while (runIterate()) ...` loop cannot:
  ///  1. Owns the `run_iterate` pump and keeps pumping even when the status is
  ///     non-GOOD, so open62541's event loop stays alive during a drop (the
  ///     usual stop-on-non-GOOD loops kill the event loop and can never
  ///     recover).
  ///  2. Watches the channel/session state and, whenever the session is not
  ///     ACTIVATED and open62541's own connect latch has gone bad, re-issues
  ///     `connect()` — resetting `connectStatus` — with capped exponential
  ///     backoff until the session is ACTIVATED again.
  ///  3. Emits [reconnectStream] on each recovery so the app can re-establish
  ///     subscriptions (which open62541 drops on disconnect).
  ///
  /// The returned future completes when the session first reaches ACTIVATED.
  /// After that the supervisor keeps running in the background until
  /// [stopKeepConnected] (or [delete]) is called. An attempt still in flight
  /// after [connectTimeout] (a peer that accepts and never answers) is
  /// abandoned and retried; `null` lets it run. This method OWNS the event
  /// loop pump — do not run your own `runIterate` loop alongside it.
  ///
  /// Existing `connect()` / `runIterate()` semantics are unchanged; recovery is
  /// entirely opt-in via this method.
  ///
  /// ## Pumping without blocking the owning isolate
  ///
  /// By default the pump calls `runIterate(iterateInterval)`, which BLOCKS the
  /// isolate inside open62541's `select()` for up to [iterateInterval]. That is
  /// why a [Client] has historically needed an isolate of its own — a 10 ms
  /// blocking pump followed by a 10 ms sleep leaves the isolate unavailable
  /// roughly half the time, which is fatal on a UI or fan-in isolate.
  ///
  /// Pass `nonBlocking: true` to poll instead: the pump calls
  /// `runIterate(Duration.zero)`, which processes due timers and drains ready
  /// sockets with a zero-timeout `select()` and returns immediately, then
  /// yields for [iterateInterval] like any other timer. The client can then
  /// live directly on the isolate that consumes its data — no [ClientIsolate],
  /// no port hop, no copy, values materialised straight onto the owning heap.
  ///
  /// With `nonBlocking: true`, [iterateInterval] is a POLL CADENCE rather than
  /// a blocking timeout, so it also sets the floor on notification latency;
  /// 1 ms is a reasonable default for a fan-in and costs a fraction of a
  /// percent of a core per idle client. See `tool/bench_pump.dart`.
  ///
  /// The default stays `false` so existing callers keep their exact current
  /// behaviour.
  ///
  /// Usage:
  /// ```dart
  /// final client = Client();
  /// await client.keepConnected('opc.tcp://localhost:4840');
  /// client.reconnectStream.listen((_) async {
  ///   // subscriptions are cleared on a drop — re-create them here
  ///   final sub = await client.subscriptionCreate();
  ///   client.monitor(myNode, sub).listen(handleValue);
  /// });
  /// ```
  ///
  /// Several clients merged on one isolate, none of them blocking it:
  /// ```dart
  /// for (final url in urls) {
  ///   final c = Client();
  ///   await c.keepConnected(url, nonBlocking: true, iterateInterval: const Duration(milliseconds: 1));
  /// }
  /// ```
  Future<void> keepConnected(
    String url, {
    Duration retryInterval = const Duration(milliseconds: 500),
    Duration maxBackoff = const Duration(seconds: 5),
    Duration iterateInterval = const Duration(milliseconds: 10),
    bool nonBlocking = false,
    Duration? connectTimeout = const Duration(seconds: 30),
  }) {
    // Restart cleanly if already supervising: the running pump and supervisor
    // check this generation on every turn and stop as soon as it has moved on,
    // so a second call replaces them instead of starting a second pair.
    final generation = ++_keepConnectedGeneration;
    final firstActivation = Completer<void>();
    _keepConnected = true;
    _startPump(iterateInterval, nonBlocking, generation);
    _superviseConnection(url, retryInterval, maxBackoff, connectTimeout, firstActivation, generation);
    return firstActivation.future;
  }

  /// Stops the auto-reconnect supervisor and its event-loop pump started by
  /// [keepConnected]. Does not disconnect an established session; call
  /// [disconnect] / [delete] separately if desired.
  void stopKeepConnected() {
    _keepConnected = false;
  }

  void _startPump(Duration iterateInterval, bool nonBlocking, int generation) {
    final timeout = nonBlocking ? Duration.zero : iterateInterval;
    () async {
      while (_keepConnected && generation == _keepConnectedGeneration && _client != ffi.nullptr) {
        // Deliberately ignore the return value: unlike a typical drive loop we
        // must NOT stop pumping when the status goes non-GOOD, otherwise the
        // event loop dies and the client can never recover.
        runIterate(timeout);
        await Future.delayed(iterateInterval);
      }
    }();
  }

  Future<void> _superviseConnection(
    String url,
    Duration retryInterval,
    Duration maxBackoff,
    Duration? connectTimeout,
    Completer<void> firstActivation,
    int generation,
  ) async {
    const pollInterval = Duration(milliseconds: 100);
    var backoff = retryInterval;
    var everActivated = false;
    var wasActivated = false;
    // How long the attempt in flight has been; null when none is.
    Stopwatch? connectingSince;

    while (_keepConnected && generation == _keepConnectedGeneration && _client != ffi.nullptr) {
      final snapshot = state;
      final activated = snapshot.sessionState == raw.UA_SessionState.UA_SESSIONSTATE_ACTIVATED;

      if (activated) {
        connectingSince = null;
        // Signal a recovery (session came back after having dropped).
        if (everActivated && !wasActivated && !_reconnectController.isClosed) {
          _reconnectController.add(null);
        }
        if (!everActivated) {
          everActivated = true;
          if (!firstActivation.isCompleted) firstActivation.complete();
        }
        wasActivated = true;
        backoff = retryInterval;
        await Future.delayed(pollInterval);
        continue;
      }

      wasActivated = false;

      // A connect/handshake is still in flight (connectStatus is GOOD and the
      // channel is not closed) — give it time rather than hammering it.
      final connecting =
          snapshot.recoveryStatus == raw.UA_STATUSCODE_GOOD &&
          snapshot.channelState != raw.UA_SecureChannelState.UA_SECURECHANNELSTATE_CLOSED;
      if (connecting) {
        connectingSince ??= Stopwatch()..start();
        if (connectTimeout == null || connectingSince.elapsed < connectTimeout) {
          await Future.delayed(pollInterval);
          continue;
        }
        // A peer that never answers keeps the attempt in flight forever:
        // abandon it and start over.
        raw.UA_Client_disconnect(_client);
      }
      connectingSince = null;

      // Either we have never connected, or the connect latch has gone bad and
      // open62541 has given up. Re-issue connect to reset connectStatus and
      // restart the state machine, then back off before re-checking.
      _issueConnect(url);
      await Future.delayed(backoff);
      backoff = backoff * 2;
      if (backoff > maxBackoff) backoff = maxBackoff;
    }
  }

  /// Drives one turn of open62541's event loop: due timers fire, ready sockets
  /// are drained, and the resulting callbacks (monitored-item notifications,
  /// service responses) run to completion BEFORE this returns — synchronously,
  /// on the calling isolate, onto the calling isolate's heap.
  ///
  /// [iterate] is a timeout, not a duration to spend: it is the longest the
  /// underlying `select()` will wait for a socket to become ready. Any non-zero
  /// value therefore BLOCKS the calling isolate for up to that long.
  ///
  /// [Duration.zero] makes it a NON-BLOCKING POLL. `UA_EventLoopPOSIX_run`
  /// clamps its listen timeout to the remaining budget, so a zero timeout
  /// reaches `select()` with a zero `timeval`: timers still fire and ready
  /// sockets are still drained, but nothing waits. This is what lets a client
  /// share an isolate with a UI or with other clients — see [keepConnected]'s
  /// `nonBlocking` argument, which owns such a loop for you.
  ///
  /// Returns whether the client's status is still GOOD. Note that a supervising
  /// loop must NOT stop on `false`: once the event loop stops being pumped the
  /// client can never recover. [keepConnected] handles that.
  bool runIterate(Duration iterate) {
    if (_client != ffi.nullptr) {
      // Get the client state
      int ms = iterate.inMilliseconds;
      return raw.UA_Client_run_iterate(_client, ms) == raw.UA_STATUSCODE_GOOD;
    }
    return false;
  }

  @override
  Future<void> write(NodeId nodeId, DynamicValue value) {
    // open62541 encodes the request before the service call returns, so the
    // buffer behind a string NodeId is scratch until then, not until the
    // write completes.
    final arena = Arena(ua_calloc);
    try {
      return _write(nodeId.toRaw(allocator: arena), value);
    } finally {
      arena.releaseAll();
    }
  }

  Future<void> _write(raw.UA_NodeId nodeId, DynamicValue value) {
    Completer<void> completer = Completer<void>();

    final variant = valueToVariant(value);

    late ffi.NativeCallable<
      ffi.Void Function(
        ffi.Pointer<raw.UA_Client>,
        ffi.Pointer<ffi.Void>,
        ffi.Uint32,
        ffi.Pointer<raw.UA_WriteResponse>,
      )
    >
    callback;
    // Create callback for this specific write request
    callback =
        ffi.NativeCallable<
          ffi.Void Function(
            ffi.Pointer<raw.UA_Client>,
            ffi.Pointer<ffi.Void>,
            ffi.Uint32,
            ffi.Pointer<raw.UA_WriteResponse>,
          )
        >.isolateLocal((
          ffi.Pointer<raw.UA_Client> client,
          ffi.Pointer<ffi.Void> userdata,
          int reqId,
          ffi.Pointer<raw.UA_WriteResponse> response,
        ) {
          // The native callback fires exactly once per request (a timeout
          // arrives here too, as a Bad_Timeout service result), so release
          // the trampoline and the variant FIRST — before any of the early
          // returns below, like readValue does. Closing only on the success
          // path leaked one native callable (and the closure and variant it
          // captured) per rejected write, and a node answering
          // Bad_NotWritable is routine on a plant.
          callback.close();
          raw.UA_Variant_delete(variant);
          // Fail with a typed UaStatusException so the exact service/operation
          // status code is programmatically extractable (e.g. a data-source
          // node rejecting the write with Bad_NotWritable).
          if (response.ref.responseHeader.serviceResult != raw.UA_STATUSCODE_GOOD) {
            completer.completeError(UaStatusException(response.ref.responseHeader.serviceResult));
            return;
          }
          if (response.ref.results.value != raw.UA_STATUSCODE_GOOD) {
            completer.completeError(UaStatusException(response.ref.results.value));
            return;
          }
          completer.complete();
        });
    final res = raw.UA_Client_writeValueAttribute_async(
      _client,
      nodeId,
      variant,
      callback.nativeFunction,
      ffi.nullptr,
      ffi.nullptr,
    );
    if (res != raw.UA_STATUSCODE_GOOD) {
      // Refused before anything was sent (Bad_ServerNotConnected: the secure
      // channel is down). The callback will never run, so release here and
      // fail typed rather than leave the caller waiting forever.
      callback.close();
      raw.UA_Variant_delete(variant);
      completer.completeError(UaStatusException(res));
    }
    return completer.future;
  }

  @override
  Stream<ClientState> get stateStream => config.stateStream;

  ClientState get state {
    ffi.Pointer<ffi.UnsignedInt> state = ua_calloc<ffi.UnsignedInt>();
    ffi.Pointer<ffi.UnsignedInt> sessionState = ua_calloc<ffi.UnsignedInt>();
    ffi.Pointer<ffi.Uint32> connectStatus = ua_calloc<ffi.Uint32>();
    raw.UA_Client_getState(_client, state, sessionState, connectStatus);
    final retValue = ClientState(
      channelState: raw.UA_SecureChannelState.fromValue(state.value),
      sessionState: raw.UA_SessionState.fromValue(sessionState.value),
      recoveryStatus: connectStatus.value,
    );
    ua_calloc.free(state);
    ua_calloc.free(sessionState);
    ua_calloc.free(connectStatus);
    return retValue;
  }

  /// Reads a value from the server.
  @override
  Future<DynamicValue> read(NodeId nodeId) async {
    final parameters = {
      nodeId: [
        AttributeId.UA_ATTRIBUTEID_DESCRIPTION,
        AttributeId.UA_ATTRIBUTEID_DISPLAYNAME,
        AttributeId.UA_ATTRIBUTEID_DATATYPE,
        AttributeId.UA_ATTRIBUTEID_VALUE,
      ],
    };
    final results = await readAttribute(parameters);

    assert(results.length == 1);
    assert(results.containsKey(nodeId));
    return results[nodeId]!;
  }

  /// Reads the Value attribute of [nodeId] together with its OPC UA status
  /// code and source/server timestamps.
  ///
  /// Unlike [read] (which throws on any non-Good status), a non-Good
  /// *operation* status does not throw here: it is returned in
  /// [DataValue.statusCode] alongside whatever value the server attached (OPC
  /// UA allows a Bad status to still carry a value — e.g. a data-source proxy
  /// serving its last-known value with `Bad_NoCommunication`). A failed
  /// *service* call (broken connection, bad service result) still completes
  /// with an error.
  @override
  Future<DataValue> readValue(NodeId nodeId) {
    final completer = Completer<DataValue>();

    final readValueId = ua_calloc<raw.UA_ReadValueId>();
    readValueId.ref.nodeId = nodeId.toRaw();
    readValueId.ref.attributeId = AttributeId.UA_ATTRIBUTEID_VALUE.value;

    final request = raw.UA_ReadRequest_new();
    raw.UA_ReadRequest_init(request);
    request.ref.nodesToRead = readValueId;
    request.ref.nodesToReadSize = 1;
    request.ref.timestampsToReturnAsInt = raw.UA_TimestampsToReturn.UA_TIMESTAMPSTORETURN_BOTH.value;

    final requestIdPtr = ua_calloc<ffi.Uint32>();

    late ffi.NativeCallable<
      ffi.Void Function(ffi.Pointer<raw.UA_Client>, ffi.Pointer<ffi.Void>, raw.UA_UInt32, ffi.Pointer<ffi.Void>)
    >
    callback;

    callback =
        ffi.NativeCallable<
          ffi.Void Function(ffi.Pointer<raw.UA_Client>, ffi.Pointer<ffi.Void>, raw.UA_UInt32, ffi.Pointer<ffi.Void>)
        >.isolateLocal((
          ffi.Pointer<raw.UA_Client> client,
          ffi.Pointer<ffi.Void> userdata,
          int requestId,
          ffi.Pointer<ffi.Void> voidPointer,
        ) async {
          callback.close();
          raw.UA_ReadRequest_delete(request);
          ua_calloc.free(requestIdPtr);

          if (voidPointer == ffi.nullptr) {
            completer.completeError('readValue callback received null pointer');
            return;
          }
          final ffi.Pointer<raw.UA_ReadResponse> response = ffi.Pointer.fromAddress(voidPointer.address);
          if (response.ref.responseHeader.serviceResult != raw.UA_STATUSCODE_GOOD) {
            completer.completeError(
              'Failed to read value: ${statusCodeToString(response.ref.responseHeader.serviceResult)}',
            );
            return;
          }
          if (response.ref.resultsSize != 1) {
            completer.completeError(
              'The connection might be broken, got no response when reading the value of $nodeId',
            );
            return;
          }

          // Steal a deep copy of the DataValue: the decode below crosses async
          // boundaries and open62541 frees the response when this callback
          // returns (same technique as readAttribute).
          final source = ua_calloc<raw.UA_DataValue>();
          source.ref = response.ref.results[0];
          final copy = raw.UA_DataValue_new();
          raw.UA_DataValue_init(copy);
          raw.UA_DataValue_copy(source, copy);
          ua_calloc.free(source);

          try {
            // UA_DataValue flag bits (see the header's bitfield, replaced by
            // the `substitute` byte in the patched bindings): hasValue 0x01,
            // hasStatus 0x02, hasSourceTimestamp 0x04, hasServerTimestamp 0x08.
            final flags = copy.ref.substitute;
            final statusCode = (flags & _hasStatusFlag) != 0 ? copy.ref.status : raw.UA_STATUSCODE_GOOD;
            final sourceTimestamp = (flags & _hasSourceTimestampFlag) != 0
                ? uaDateTimeToDateTime(copy.ref.sourceTimestamp)
                : null;
            final serverTimestamp = (flags & _hasServerTimestampFlag) != 0
                ? uaDateTimeToDateTime(copy.ref.serverTimestamp)
                : null;
            DynamicValue value = DynamicValue();
            if ((flags & _hasValueFlag) != 0 && copy.ref.value.data != ffi.nullptr) {
              value = await _variantToValueAutoSchema(copy.ref.value);
            }
            if (!completer.isCompleted) {
              completer.complete(
                DataValue(
                  value: value,
                  statusCode: statusCode,
                  sourceTimestamp: sourceTimestamp,
                  serverTimestamp: serverTimestamp,
                ),
              );
            }
          } catch (e, st) {
            if (!completer.isCompleted) completer.completeError(e, st);
          } finally {
            raw.UA_DataValue_delete(copy);
          }
        });

    final res = raw.UA_Client_AsyncService(
      _client,
      request.cast(),
      getType(UaTypes.readRequest),
      callback.nativeFunction,
      getType(UaTypes.readResponse),
      ffi.nullptr,
      requestIdPtr,
    );
    if (res != raw.UA_STATUSCODE_GOOD) {
      callback.close();
      raw.UA_ReadRequest_delete(request);
      ua_calloc.free(requestIdPtr);
      completer.completeError('Failed to read value: ${statusCodeToString(res)}');
    }

    return completer.future;
  }

  // Reimplementation of the readAttribute method from open62541
  // this method on the flutter side has the same purpose. To deal with
  // the complexity of calling the underlying service and provide a
  // single point of entry for all read operations.
  @override
  Future<Map<NodeId, DynamicValue>> readAttribute(ReadAttributeParam nodes) async {
    final nodeCount = nodes.entries.map<int>((entry) => entry.value.length).fold(0, (prev, curr) => prev + curr);
    ffi.Pointer<raw.UA_ReadValueId> readValueId = ua_calloc<raw.UA_ReadValueId>(nodeCount);
    final completer = Completer<Map<NodeId, DynamicValue>>();
    final indorderNodes = [];
    var index = 0;
    for (var entry in nodes.entries) {
      for (var attributeId in entry.value) {
        readValueId[index].nodeId = entry.key.toRaw();
        readValueId[index].attributeId = attributeId.value;
        index++;
        indorderNodes.add((entry.key, attributeId));
      }
    }
    assert(index == nodeCount);

    ffi.Pointer<raw.UA_ReadRequest> request = raw.UA_ReadRequest_new();
    raw.UA_ReadRequest_init(request);
    request.ref.nodesToRead = readValueId;
    request.ref.nodesToReadSize = nodeCount;
    request.ref.timestampsToReturnAsInt = raw.UA_TimestampsToReturn.UA_TIMESTAMPSTORETURN_BOTH.value;

    ffi.Pointer<ffi.Uint32> requestIdPtr = ua_calloc<ffi.Uint32>();

    late ffi.NativeCallable<
      ffi.Void Function(ffi.Pointer<raw.UA_Client>, ffi.Pointer<ffi.Void>, raw.UA_UInt32, ffi.Pointer<ffi.Void>)
    >
    callback;

    callback =
        ffi.NativeCallable<
          ffi.Void Function(ffi.Pointer<raw.UA_Client>, ffi.Pointer<ffi.Void>, raw.UA_UInt32, ffi.Pointer<ffi.Void>)
        >.isolateLocal((
          ffi.Pointer<raw.UA_Client> client,
          ffi.Pointer<ffi.Void> userdata,
          int requestId,
          ffi.Pointer<ffi.Void> voidPointer,
        ) async {
          // Cleanup request and callback method
          callback.close();
          raw.UA_ReadRequest_delete(request);
          ua_calloc.free(requestIdPtr);

          if (voidPointer == ffi.nullptr) {
            completer.completeError('readAttribute callback received null pointer');
            return;
          }
          ffi.Pointer<raw.UA_ReadResponse> response = ffi.Pointer.fromAddress(voidPointer.address);

          // Check the service-level status FIRST: a failed service (session
          // torn down, secure channel closed, request timeout, ...) answers
          // with zero results, and reporting that as a generic "no response"
          // masks the real failure status.
          if (response.ref.responseHeader.serviceResult != raw.UA_STATUSCODE_GOOD) {
            completer.completeError(UaStatusException(response.ref.responseHeader.serviceResult), StackTrace.current);
            return;
          }

          List<ffi.Pointer<raw.UA_DataValue>> pointers = [];

          // Steal the data_value pointer from open62541 so they don't delete it
          // if we don't do this, the data_value will be freed on a flutter async
          // boundary. f.e. while we fetch the structure of a schema.
          // because the callback we are currently in "returns" before completing.
          ffi.Pointer<raw.UA_DataValue> source = ua_calloc<raw.UA_DataValue>();
          for (var i = 0; i < response.ref.resultsSize; i++) {
            pointers.add(raw.UA_DataValue_new());
            raw.UA_DataValue_init(pointers.last);
            source.ref = response.ref.results[i];
            raw.UA_DataValue_copy(source, pointers.last);
          }
          ua_calloc.free(source);

          assert(pointers.length == response.ref.resultsSize);
          if (pointers.length != nodeCount && pointers.isEmpty) {
            completer.completeError(
              "The connection might be broken, got no response when reading attributes for nodes: $nodes",
              StackTrace.current,
            );
            return;
          }
          assert(nodeCount == pointers.length);

          try {
            final retVal = <NodeId, DynamicValue>{};
            for (var i = 0; i < pointers.length; i++) {
              final status = pointers[i].ref.status;
              final attributeId = indorderNodes[i].$2;

              if (status != raw.UA_STATUSCODE_GOOD) {
                // Tolerate attributes a server legitimately doesn't expose:
                //  - DESCRIPTION: optional metadata, not all servers have it.
                //  - DATATYPEDEFINITION: only structured/enum types have one; a
                //    simple type (incl. vendor DataType aliases like TwinCAT's
                //    STRING at a custom NodeId) returns BadAttributeIdInvalid.
                if (status == raw.UA_STATUSCODE_BADATTRIBUTEIDINVALID &&
                    (attributeId == AttributeId.UA_ATTRIBUTEID_DESCRIPTION ||
                        attributeId == AttributeId.UA_ATTRIBUTEID_DATATYPEDEFINITION)) {
                  continue;
                }
                completer.completeError(
                  'Failed to read attribute: ${statusCodeToString(status)} NodeId: ${indorderNodes[i].$1} AttributeId: $attributeId',
                );
                break; // Break here to cleanup pointers memory below
              }

              final ok = status == raw.UA_STATUSCODE_GOOD;
              var reference = retVal[indorderNodes[i].$1] ?? DynamicValue();
              raw.UA_Variant? value = ok ? pointers[i].ref.value : null;

              // A server may legally answer Good with an EMPTY variant: "the
              // attribute exists and carries no value" (Part 4 — asyncua does
              // this for the DataTypeDefinition of every base DataType node;
              // TwinCAT answers BadAttributeIdInvalid instead). An empty
              // variant has type == NULL and data == NULL, so every case below
              // would dereference NULL natively — a process-killing SIGSEGV,
              // not a catchable Dart error. Treat it exactly like the
              // tolerated BadAttributeIdInvalid above: the attribute is
              // absent.
              //
              // Except for VALUE, where empty is a value: the node was read
              // and its value is null, which is what the monitor path and
              // read() report. That case goes on into the switch, where
              // _variantToValueAutoSchema answers a null DynamicValue.
              if (value != null && value.type == ffi.nullptr && attributeId != AttributeId.UA_ATTRIBUTEID_VALUE) {
                continue;
              }

              switch (indorderNodes[i].$2) {
                case AttributeId.UA_ATTRIBUTEID_DESCRIPTION:
                  final description = value!.data.cast<raw.UA_LocalizedText>();
                  reference.description = LocalizedText(description.ref.text.value, description.ref.locale.value);
                case AttributeId.UA_ATTRIBUTEID_DISPLAYNAME:
                  final displayName = value!.data.cast<raw.UA_LocalizedText>();
                  reference.displayName = LocalizedText(displayName.ref.text.value, displayName.ref.locale.value);
                case AttributeId.UA_ATTRIBUTEID_DATATYPE:
                  final dataType = value!.data.cast<raw.UA_NodeId>();
                  reference.typeId = dataType.ref.toNodeId();
                case AttributeId.UA_ATTRIBUTEID_VALUE:
                  final temporary = await _variantToValueAutoSchema(value!, reference.typeId);
                  reference.value = temporary.value;
                  reference.typeId = reference.typeId ?? temporary.typeId; // Prefer explicitly fetched type id
                  reference.enumFields = reference.enumFields ?? temporary.enumFields;
                  reference.extObjEncodingId = reference.extObjEncodingId ?? temporary.extObjEncodingId;
                case AttributeId.UA_ATTRIBUTEID_VALUERANK:
                case AttributeId.UA_ATTRIBUTEID_ARRAYDIMENSIONS:
                  // An Int32 scalar / a UInt32 array, delivered as the value
                  // (read one of them per call: both land in `value`).
                  reference.value = (await _variantToValueAutoSchema(value!, null)).value;
                case AttributeId.UA_ATTRIBUTEID_DATATYPEDEFINITION:
                  final temporary = OpcUaDynamicValueSerializer.fromDataTypeDefinition(
                    reference.typeId ?? value!.type.ref.typeId.toNodeId(),
                    value!,
                  );
                  reference.value = temporary.value;
                  reference.typeId = reference.typeId ?? temporary.typeId;
                  reference.enumFields = reference.enumFields ?? temporary.enumFields;
                  reference.extObjEncodingId = reference.extObjEncodingId ?? temporary.extObjEncodingId;
                default:
                  throw 'Unhandled attribute id ${indorderNodes[i].$2}';
              }
              retVal[indorderNodes[i].$1] = reference;
            }
            if (!completer.isCompleted) completer.complete(retVal);
          } catch (e, st) {
            if (!completer.isCompleted) completer.completeError(e, st);
          } finally {
            for (var element in pointers) {
              raw.UA_DataValue_delete(element);
            }
          }
        });

    int res = raw.UA_Client_AsyncService(
      _client,
      request.cast(),
      getType(UaTypes.readRequest),
      callback.nativeFunction,
      getType(UaTypes.readResponse),
      ffi.nullptr,
      requestIdPtr,
    );
    if (res != raw.UA_STATUSCODE_GOOD) {
      callback.close();
      raw.UA_ReadRequest_delete(request);
      ua_calloc.free(requestIdPtr);
      completer.completeError('Failed to read attribute: ${statusCodeToString(res)}');
      return completer.future;
    }

    return completer.future;
  }

  Future<NodeId> readDataTypeAttribute(NodeId nodeId) async {
    final parameters = {
      nodeId: [AttributeId.UA_ATTRIBUTEID_DATATYPE],
    };
    final results = await readAttribute(parameters);
    assert(results.length == 1);
    assert(results.containsKey(nodeId));
    return results[nodeId]!.typeId!;
  }

  @override
  Future<List<BrowseResultItem>> browse(
    NodeId nodeId, {
    int direction = 0,
    NodeId? referenceTypeId,
    bool includeSubtypes = true,
    int nodeClassMask = 0,
    BrowseResultMask resultMask = BrowseResultMask.UA_BROWSERESULTMASK_ALL,
  }) async {
    final results = await _browseRequest(
      nodeId,
      direction: direction,
      referenceTypeId: referenceTypeId,
      includeSubtypes: includeSubtypes,
      nodeClassMask: nodeClassMask,
      resultMask: resultMask.value,
    );
    return results;
  }

  @override
  Stream<BrowseTreeItem> browseTree(
    NodeId root, {
    int maxDepth = 100,
    NodeId? referenceTypeId,
    bool includeSubtypes = true,
    Set<NodeClass> recurseInto = const {NodeClass.UA_NODECLASS_OBJECT, NodeClass.UA_NODECLASS_VIEW},
  }) {
    final controller = StreamController<BrowseTreeItem>();

    () async {
      final visited = <NodeId>{};

      Future<void> walk(NodeId nodeId, int depth) async {
        if (depth > maxDepth || controller.isClosed) return;
        if (visited.contains(nodeId)) return;
        visited.add(nodeId);

        final children = await browse(nodeId, referenceTypeId: referenceTypeId, includeSubtypes: includeSubtypes);

        for (final child in children) {
          if (controller.isClosed) return;
          controller.add(BrowseTreeItem(item: child, depth: depth, parentNodeId: nodeId));

          if (recurseInto.contains(child.nodeClass)) {
            await walk(child.nodeId, depth + 1);
          }
        }
      }

      try {
        await walk(root, 0);
      } catch (e) {
        controller.addError(e);
      } finally {
        controller.close();
      }
    }();

    return controller.stream;
  }

  Future<List<BrowseResultItem>> _browseRequest(
    NodeId nodeId, {
    required int direction,
    NodeId? referenceTypeId,
    required bool includeSubtypes,
    required int nodeClassMask,
    required int resultMask,
  }) {
    final completer = Completer<List<BrowseResultItem>>();

    final request = raw.UA_BrowseRequest_new();
    raw.UA_BrowseRequest_init(request);

    final browseDescription = ua_calloc<raw.UA_BrowseDescription>();
    raw.UA_BrowseDescription_init(browseDescription);
    browseDescription.ref.nodeId = nodeId.toRaw();
    browseDescription.ref.browseDirectionAsInt = direction;
    browseDescription.ref.includeSubtypes = includeSubtypes;
    browseDescription.ref.nodeClassMask = nodeClassMask;
    browseDescription.ref.resultMask = resultMask;
    if (referenceTypeId != null) {
      browseDescription.ref.referenceTypeId = referenceTypeId.toRaw();
    }

    request.ref.nodesToBrowse = browseDescription;
    request.ref.nodesToBrowseSize = 1;
    request.ref.requestedMaxReferencesPerNode = 0;

    ffi.Pointer<ffi.Uint32> requestIdPtr = ua_calloc<ffi.Uint32>();

    late ffi.NativeCallable<
      ffi.Void Function(ffi.Pointer<raw.UA_Client>, ffi.Pointer<ffi.Void>, raw.UA_UInt32, ffi.Pointer<ffi.Void>)
    >
    callback;

    callback =
        ffi.NativeCallable<
          ffi.Void Function(ffi.Pointer<raw.UA_Client>, ffi.Pointer<ffi.Void>, raw.UA_UInt32, ffi.Pointer<ffi.Void>)
        >.isolateLocal((
          ffi.Pointer<raw.UA_Client> client,
          ffi.Pointer<ffi.Void> userdata,
          int requestId,
          ffi.Pointer<ffi.Void> voidPointer,
        ) async {
          callback.close();
          raw.UA_BrowseRequest_delete(request);
          ua_calloc.free(requestIdPtr);

          if (voidPointer == ffi.nullptr) {
            completer.completeError('Browse callback received null pointer');
            return;
          }

          ffi.Pointer<raw.UA_BrowseResponse> response = ffi.Pointer.fromAddress(voidPointer.address);

          if (response.ref.responseHeader.serviceResult != raw.UA_STATUSCODE_GOOD) {
            completer.completeError('Browse failed: ${statusCodeToString(response.ref.responseHeader.serviceResult)}');
            return;
          }

          if (response.ref.resultsSize == 0) {
            completer.complete([]);
            return;
          }

          final browseResult = response.ref.results[0];
          if (browseResult.statusCode != raw.UA_STATUSCODE_GOOD) {
            completer.completeError(_BrowseResultError(browseResult.statusCode));
            return;
          }

          final items = _extractReferences(browseResult);

          // Handle continuation point
          if (browseResult.continuationPoint.length > 0) {
            // Copy continuation point data before response is freed
            final cpData = ua_calloc<ffi.Uint8>(browseResult.continuationPoint.length);
            cpData
                .asTypedList(browseResult.continuationPoint.length)
                .setRange(
                  0,
                  browseResult.continuationPoint.length,
                  browseResult.continuationPoint.data.asTypedList(browseResult.continuationPoint.length),
                );

            try {
              final moreItems = await _browseNext(cpData, browseResult.continuationPoint.length);
              items.addAll(moreItems);
            } catch (e) {
              completer.completeError(e);
              return;
            }
          }

          completer.complete(items);
        });

    int res = raw.UA_Client_AsyncService(
      _client,
      request.cast(),
      getType(UaTypes.browseRequest),
      callback.nativeFunction,
      getType(UaTypes.browseResponse),
      ffi.nullptr,
      requestIdPtr,
    );
    if (res != raw.UA_STATUSCODE_GOOD) {
      callback.close();
      raw.UA_BrowseRequest_delete(request);
      ua_calloc.free(requestIdPtr);
      completer.completeError('Failed to browse: ${statusCodeToString(res)}');
    }

    return completer.future;
  }

  Future<List<BrowseResultItem>> _browseNext(
    ffi.Pointer<ffi.Uint8> continuationPointData,
    int continuationPointLength,
  ) {
    final completer = Completer<List<BrowseResultItem>>();

    final request = raw.UA_BrowseNextRequest_new();
    raw.UA_BrowseNextRequest_init(request);
    request.ref.releaseContinuationPoints = false;
    // From here on the request owns `cp` and, through it, the caller's
    // [continuationPointData]: UA_BrowseNextRequest_delete frees both.
    final cp = ua_calloc<raw.UA_ByteString>();
    cp.ref.data = continuationPointData;
    cp.ref.length = continuationPointLength;
    request.ref.continuationPoints = cp;
    request.ref.continuationPointsSize = 1;

    ffi.Pointer<ffi.Uint32> requestIdPtr = ua_calloc<ffi.Uint32>();

    late ffi.NativeCallable<
      ffi.Void Function(ffi.Pointer<raw.UA_Client>, ffi.Pointer<ffi.Void>, raw.UA_UInt32, ffi.Pointer<ffi.Void>)
    >
    callback;

    callback =
        ffi.NativeCallable<
          ffi.Void Function(ffi.Pointer<raw.UA_Client>, ffi.Pointer<ffi.Void>, raw.UA_UInt32, ffi.Pointer<ffi.Void>)
        >.isolateLocal((
          ffi.Pointer<raw.UA_Client> client,
          ffi.Pointer<ffi.Void> userdata,
          int requestId,
          ffi.Pointer<ffi.Void> voidPointer,
        ) async {
          callback.close();
          ua_calloc.free(requestIdPtr);

          // The request owns the continuation point (see above): deleting it
          // frees `cp` and its data as well.
          raw.UA_BrowseNextRequest_delete(request);

          if (voidPointer == ffi.nullptr) {
            completer.completeError('BrowseNext callback received null pointer');
            return;
          }

          ffi.Pointer<raw.UA_BrowseNextResponse> response = ffi.Pointer.fromAddress(voidPointer.address);

          if (response.ref.responseHeader.serviceResult != raw.UA_STATUSCODE_GOOD) {
            completer.completeError(
              'BrowseNext failed: ${statusCodeToString(response.ref.responseHeader.serviceResult)}',
            );
            return;
          }

          if (response.ref.resultsSize == 0) {
            completer.complete([]);
            return;
          }

          final browseResult = response.ref.results[0];
          if (browseResult.statusCode != raw.UA_STATUSCODE_GOOD) {
            completer.completeError('BrowseNext result error: ${statusCodeToString(browseResult.statusCode)}');
            return;
          }

          final items = _extractReferences(browseResult);

          // Continue if there are more results
          if (browseResult.continuationPoint.length > 0) {
            final nextCpData = ua_calloc<ffi.Uint8>(browseResult.continuationPoint.length);
            nextCpData
                .asTypedList(browseResult.continuationPoint.length)
                .setRange(
                  0,
                  browseResult.continuationPoint.length,
                  browseResult.continuationPoint.data.asTypedList(browseResult.continuationPoint.length),
                );
            try {
              final moreItems = await _browseNext(nextCpData, browseResult.continuationPoint.length);
              items.addAll(moreItems);
            } catch (e) {
              completer.completeError(e);
              return;
            }
          }

          completer.complete(items);
        });

    int res = raw.UA_Client_AsyncService(
      _client,
      request.cast(),
      getType(UaTypes.browseNextRequest),
      callback.nativeFunction,
      getType(UaTypes.browseNextResponse),
      ffi.nullptr,
      requestIdPtr,
    );
    if (res != raw.UA_STATUSCODE_GOOD) {
      callback.close();
      raw.UA_BrowseNextRequest_delete(request);
      ua_calloc.free(requestIdPtr);
      completer.completeError('Failed to browse next: ${statusCodeToString(res)}');
    }

    return completer.future;
  }

  static NodeId? _tryNodeId(raw.UA_NodeId rawNodeId) {
    try {
      return rawNodeId.toNodeId();
    } catch (_) {
      return null;
    }
  }

  List<BrowseResultItem> _extractReferences(raw.UA_BrowseResult browseResult) {
    final items = <BrowseResultItem>[];
    for (var i = 0; i < browseResult.referencesSize; i++) {
      final ref = browseResult.references[i];
      final nodeId = _tryNodeId(ref.nodeId.nodeId);
      if (nodeId == null) continue;
      items.add(
        BrowseResultItem(
          referenceTypeId: _tryNodeId(ref.referenceTypeId) ?? NodeId.nullId,
          isForward: ref.isForward,
          nodeId: nodeId,
          browseName: ref.browseName.name.value,
          displayName: ref.displayName.text.value,
          nodeClass: ref.nodeClass,
          typeDefinition: _tryNodeId(ref.typeDefinition.nodeId),
        ),
      );
    }
    return items;
  }

  @override
  Future<int> subscriptionCreate({
    Duration requestedPublishingInterval = const Duration(milliseconds: 100),
    int requestedLifetimeCount = 10000,
    int requestedMaxKeepAliveCount = 10,
    int maxNotificationsPerPublish = 0,
    bool publishingEnabled = true,
    int priority = 0,
  }) {
    ffi.Pointer<raw.UA_CreateSubscriptionRequest> request = raw.UA_CreateSubscriptionRequest_new();
    raw.UA_CreateSubscriptionRequest_init(request);
    request.ref.requestedPublishingInterval = requestedPublishingInterval.inMicroseconds / 1000.0;
    request.ref.requestedLifetimeCount = requestedLifetimeCount;
    request.ref.requestedMaxKeepAliveCount = requestedMaxKeepAliveCount;
    request.ref.maxNotificationsPerPublish = maxNotificationsPerPublish;
    request.ref.publishingEnabled = publishingEnabled;
    request.ref.priority = priority;

    late ffi.NativeCallable<ffi.Void Function(ffi.Pointer<raw.UA_Client>, ffi.Uint32, ffi.Pointer<ffi.Void>)>
    deleteCallback;

    deleteCallback =
        ffi.NativeCallable<
          ffi.Void Function(ffi.Pointer<raw.UA_Client>, ffi.Uint32, ffi.Pointer<ffi.Void>)
        >.isolateLocal((ffi.Pointer<raw.UA_Client> client, int subId, ffi.Pointer<ffi.Void> subContext) {
          config._subscriptionDeleted.add(subId);
          _subscriptionDeleteCallbacks.remove(deleteCallback);
          deleteCallback.close();
        });
    _subscriptionDeleteCallbacks.add(deleteCallback);

    final completer = Completer<int>();
    late ffi.NativeCallable<
      ffi.Void Function(
        ffi.Pointer<raw.UA_Client>,
        ffi.Pointer<ffi.Void>,
        ffi.Uint32,
        ffi.Pointer<raw.UA_CreateSubscriptionResponse>,
      )
    >
    callback;

    callback =
        ffi.NativeCallable<
          ffi.Void Function(
            ffi.Pointer<raw.UA_Client>,
            ffi.Pointer<ffi.Void>,
            ffi.Uint32,
            ffi.Pointer<raw.UA_CreateSubscriptionResponse>,
          )
        >.isolateLocal((
          ffi.Pointer<raw.UA_Client> client,
          ffi.Pointer<ffi.Void> somedata,
          int requestId,
          ffi.Pointer<raw.UA_CreateSubscriptionResponse> response,
        ) {
          raw.UA_CreateSubscriptionRequest_delete(request);
          callback.close();
          if (response.ref.responseHeader.serviceResult != raw.UA_STATUSCODE_GOOD) {
            completer.completeError(
              'unable to create subscription ${response.ref.responseHeader.serviceResult} ${statusCodeToString(response.ref.responseHeader.serviceResult)}',
            );
            return;
          }
          completer.complete(response.ref.subscriptionId);
        });

    final res = raw.UA_Client_Subscriptions_create_async(
      _client,
      request.ref,
      ffi.nullptr,
      ffi.nullptr,
      deleteCallback.nativeFunction,
      callback.nativeFunction,
      ffi.nullptr,
      ffi.nullptr,
    );
    if (res != raw.UA_STATUSCODE_GOOD) {
      // Refused before anything was sent (Bad_ServerNotConnected): neither
      // callback will ever run, and the subscription the delete callback was
      // registered for will never exist. Release both and fail typed rather
      // than leave the caller waiting forever.
      raw.UA_CreateSubscriptionRequest_delete(request);
      callback.close();
      _subscriptionDeleteCallbacks.remove(deleteCallback);
      deleteCallback.close();
      completer.completeError(UaStatusException(res));
    }
    return completer.future;
  }

  /// Creates a monitored item on the server.
  ///
  /// A sample with a non-Good status is added to the stream as a
  /// [UaStatusException] error and nothing is delivered for it; see
  /// [monitoredDataValues] for the sample with its status instead.
  @override
  Stream<Map<NodeId, DynamicValue>> monitoredItems(
    ReadAttributeParam nodes,
    int subscriptionId, {
    MonitoringMode monitoringMode = MonitoringMode.UA_MONITORINGMODE_REPORTING,
    Duration samplingInterval = const Duration(milliseconds: 100),
    bool discardOldest = true,
    int queueSize = 1,
  }) => _monitoredItemsCore<Map<NodeId, DynamicValue>>(
    nodes,
    subscriptionId,
    monitoringMode: monitoringMode,
    samplingInterval: samplingInterval,
    discardOldest: discardOldest,
    queueSize: queueSize,
    deliverQuality: false,
    // The one map the stream has always emitted: the same mutable object
    // every time, updated in place between events.
    project: (latestValues, _) => latestValues,
  );

  @override
  Stream<Map<NodeId, DataValue>> monitoredDataValues(
    ReadAttributeParam nodes,
    int subscriptionId, {
    MonitoringMode monitoringMode = MonitoringMode.UA_MONITORINGMODE_REPORTING,
    Duration samplingInterval = const Duration(milliseconds: 100),
    bool discardOldest = true,
    int queueSize = 1,
  }) => _monitoredItemsCore<Map<NodeId, DataValue>>(
    nodes,
    subscriptionId,
    monitoringMode: monitoringMode,
    samplingInterval: samplingInterval,
    discardOldest: discardOldest,
    queueSize: queueSize,
    deliverQuality: true,
    // A fresh map of fresh DataValues over deep copies of the values, so an
    // event a consumer keeps is not rewritten by the next notification. The
    // isolate client copies anyway when it crosses the SendPort; the direct
    // client copies here so both deliver the same thing.
    project: (latestValues, qualities) => {
      for (final entry in latestValues.entries)
        entry.key: (qualities[entry.key] ?? const _SampleQuality.unknown()).toDataValue(DynamicValue.from(entry.value)),
    },
  );

  /// The monitored-item machinery behind [monitoredItems] and
  /// [monitoredDataValues]: one stream of events, each built by [project] from
  /// the latest value per node and the quality of each node's latest Value
  /// sample.
  ///
  /// [deliverQuality] decides what a sample with a non-Good status becomes:
  /// `false` adds it to the stream as a [UaStatusException] error and delivers
  /// nothing for it (what [monitoredItems] has always done); `true` records
  /// its status and timestamps in the node's quality and lets it through like
  /// any other sample, except that a Bad sample of an attribute other than
  /// Value, which has no quality to travel in, is still reported as the error.
  /// It also asks the server for both timestamps, as [readValue] does; the
  /// request [monitoredItems] has always sent asks for the source one only.
  Stream<T> _monitoredItemsCore<T>(
    ReadAttributeParam nodes,
    int subscriptionId, {
    required MonitoringMode monitoringMode,
    required Duration samplingInterval,
    required bool discardOldest,
    required int queueSize,
    required bool deliverQuality,
    required T Function(Map<NodeId, DynamicValue> latestValues, Map<NodeId, _SampleQuality> qualities) project,
  }) {
    final controller = StreamController<T>();

    // We define our monitor callback here so we can use it in the onListen and onCancel closures
    late ffi.NativeCallable<
      ffi.Void Function(
        ffi.Pointer<raw.UA_Client>,
        ffi.Uint32,
        ffi.Pointer<ffi.Void>,
        ffi.Uint32,
        ffi.Pointer<ffi.Void>,
        ffi.Pointer<raw.UA_DataValue>,
      )
    >
    monitorCallback;

    // figure out the size of the node set
    final nodeCount = nodes.entries.map<int>((entry) => entry.value.length).fold(0, (prev, curr) => prev + curr);
    var descriptionFailureCount = 0;

    // Since the api we are using handles creating multiple monitored items at once, we need to create an array of callbacks
    final callbacks =
        ua_calloc<
          ffi.Pointer<
            ffi.NativeFunction<
              ffi.Void Function(
                ffi.Pointer<raw.UA_Client>,
                ffi.Uint32,
                ffi.Pointer<ffi.Void>,
                ffi.Uint32,
                ffi.Pointer<ffi.Void>,
                ffi.Pointer<raw.UA_DataValue>,
              )
            >
          >
        >(nodeCount);

    // Store the monitored item id here so we can use it in the onCancel closure
    List<int> monIds = [];
    // Set when the stream is cancelled while CreateMonitoredItems is still in
    // flight. The Cancel service only stops requests the server has not begun
    // processing, so the server usually creates the items anyway; when the
    // create response finally arrives, createCallback checks this flag and
    // sends a real DeleteMonitoredItems for whatever the server created.
    // Without this the items leak server-side forever (they keep sampling and
    // publishing; open62541 drops each notification with "Could not process a
    // notification with clienthandle N") — the "stale keys" orphan bug.
    bool cancelledInFlight = false;
    ffi.Pointer<ffi.Uint32> localRequestId = ffi.nullptr;
    // Item identity must exist BEFORE the create request is sent: the server may
    // put a PublishResponse carrying the initial values on the wire before the
    // CreateMonitoredItemsResponse is processed, and open62541 dispatches those
    // early notifications with monitoredItemId still 0 (the id is only assigned
    // once the create response arrives). A monId-keyed map cannot identify them,
    // so each item instead carries its request-order index as its monitored-item
    // context — an opaque pointer open62541 stores at request time and hands
    // back to every data callback — and this list resolves index -> item.
    final List<(NodeId, AttributeId)> itemOrder = [];

    // Track config stream subscriptions so we can cancel them on close
    StreamSubscription? inactivitySub, deletedSub, stateSub;

    // Drops this item's listeners on the config's broadcast streams. Called
    // from EVERY path that ends the item — the cancel, the client delete, the
    // refused create, the partial create — so the release is deterministic.
    // Each listener closure captures this item's value map (`latestValues`
    // below), so a listener that outlives its item pins the key's last value,
    // enum fields and localized texts included. The `controller.isClosed`
    // guard inside each listener is only a backstop: it fires on the NEXT
    // event on that stream, and on a quiet client that is never.
    void releaseConfigListeners() {
      inactivitySub?.cancel();
      deletedSub?.cancel();
      stateSub?.cancel();
      inactivitySub = null;
      deletedSub = null;
      stateSub = null;
    }

    // The actual teardown of the native monitored items and callables. This is
    // invoked either through the stream's onCancel (normal user cancellation) or
    // directly by Client.delete() via the _activeMonitoredStreams registry, so
    // that active streams are always torn down before UA_Client_delete frees the
    // native client (otherwise an in-flight Publish notification would be
    // delivered into a freed NativeCallable and crash the VM with a SEGV).
    Future<void> monitorTeardown() {
      releaseConfigListeners();
      final completer = Completer<void>();
      if (monIds.isEmpty) {
        if (localRequestId == ffi.nullptr) {
          // The create was answered and left no item: every node was refused
          // with a tolerated status, so the stream stayed open with nothing
          // behind it. There is nothing to delete on the server. open62541
          // dropped its own item for each refused result before it delivered
          // the create response, so no native code can invoke monitorCallback
          // any more and it can be closed right here.
          monitorCallback.close();
          completer.complete();
        } else {
          // The monitored item request has not yet returned. Ask the server to
          // cancel it (best effort — Cancel only affects requests it has not
          // started processing) and leave a marker so createCallback deletes
          // whatever the server did create once the response arrives. Note the
          // cancel call below pumps the connection synchronously, so the
          // create response can be processed (and the deferred delete sent)
          // before it even returns.
          cancelledInFlight = true;
          raw.UA_Client_cancelByRequestId(_client, localRequestId.value, ffi.nullptr);
          completer.complete();
        }
      } else {
        final request = raw.UA_DeleteMonitoredItemsRequest_new();
        raw.UA_DeleteMonitoredItemsRequest_init(request);
        request.ref.subscriptionId = subscriptionId;
        final ids = ua_calloc<ffi.Uint32>(monIds.length);
        for (var i = 0; i < monIds.length; i++) {
          ids[i] = monIds[i];
        }
        request.ref.monitoredItemIds = ids;
        request.ref.monitoredItemIdsSize = monIds.length;
        request.ref.subscriptionId = subscriptionId;

        late ffi.NativeCallable<
          ffi.Void Function(
            ffi.Pointer<raw.UA_Client>,
            ffi.Pointer<ffi.Void>,
            ffi.Uint32,
            ffi.Pointer<raw.UA_DeleteMonitoredItemsResponse>,
          )
        >
        deleteCallback;
        deleteCallback =
            ffi.NativeCallable<
              ffi.Void Function(
                ffi.Pointer<raw.UA_Client>,
                ffi.Pointer<ffi.Void>,
                ffi.Uint32,
                ffi.Pointer<raw.UA_DeleteMonitoredItemsResponse>,
              )
            >.isolateLocal((
              ffi.Pointer<raw.UA_Client> client,
              ffi.Pointer<ffi.Void> userdata,
              int requestId,
              ffi.Pointer<raw.UA_DeleteMonitoredItemsResponse> response,
            ) {
              // Did open62541 drop its own items? It does so before it
              // invokes this callback, and only for a Good service result and
              // a Good or BadMonitoredItemIdInvalid result per item. In every
              // other case its items are still there, and usually the
              // server's too: the response was lost with the channel
              // (answered locally, BadSecureChannelClosed, with no results),
              // the request timed out, or the service failed.
              var itemsGone = false;
              if (response == ffi.nullptr) {
                _safeErr(
                  "Error deleting monitored item, nullptr provided connection propably already closed. Client cleanup.",
                );
              } else if (response.ref.responseHeader.serviceResult != raw.UA_STATUSCODE_GOOD ||
                  response.ref.resultsSize == 0) {
                final serviceResult = response.ref.responseHeader.serviceResult;
                _safeErr(
                  "Error deleting monitored item, no results provided, connection propably already closed "
                  "($serviceResult ${statusCodeToString(serviceResult)}). Client cleanup.",
                );
              } else {
                itemsGone = response.ref.resultsSize == monIds.length;
                for (var i = 0; i < response.ref.resultsSize; i++) {
                  final result = response.ref.results[i];
                  if (result != raw.UA_STATUSCODE_GOOD) {
                    _safeErr("Error deleting monitored item: $result ${statusCodeToString(result)}");
                    if (result != raw.UA_STATUSCODE_BADMONITOREDITEMIDINVALID) itemsGone = false;
                  }
                }
              }
              raw.UA_DeleteMonitoredItemsRequest_delete(request); // This frees ids as well
              deleteCallback.close();
              if (itemsGone) {
                // Defer closing monitorCallback: a Publish response processed
                // later in the same runIterate batch may still invoke it.
                // scheduleMicrotask runs after runIterate returns to the event
                // loop, so all native callbacks in the current batch complete first.
                scheduleMicrotask(() => monitorCallback.close());
                monIds.clear();
              } else {
                // An item that survived publishes again once the session is
                // re-activated, and closing monitorCallback now would abort
                // the VM on that notification ("Callback invoked after it has
                // been deleted"). As on the not-sent path below, the client
                // closes it in delete().
                _undeletedMonitorCallbacks.add(monitorCallback);
              }
              completer.complete();
            });
        final res = raw.UA_Client_MonitoredItems_delete_async(
          _client,
          request.ref,
          deleteCallback.nativeFunction,
          ffi.nullptr,
          ffi.nullptr,
        );
        if (res != raw.UA_STATUSCODE_GOOD) {
          // Refused before anything was sent (Bad_ServerNotConnected: the
          // secure channel is down, which is exactly when a caller reacting
          // to SecureChannelClosed cancels). deleteCallback will never run,
          // so release what it would have released and complete — a cancel
          // the caller awaits must not hang forever.
          //
          // monitorCallback cannot be closed here: the request never left,
          // so the native client still holds the items, and so does the
          // server if the session outlives the channel drop. The session is
          // then re-activated on reconnect and the items publish again, into
          // this callback, which drops the notifications. It is handed to
          // the client instead, which closes it in delete() once
          // UA_Client_delete has freed the items.
          //
          // Known limitation: the delete is not retried when the session
          // comes back, so the server keeps sampling an item nobody listens
          // to until the session or the subscription ends. A retry has to
          // tell a re-activated session from a recreated one, where the
          // stale ids can name a new subscription's items.
          _safeErr(
            "Error deleting monitored item, request not sent: $res ${statusCodeToString(res)}. "
            "The native client releases it with the session.",
          );
          raw.UA_DeleteMonitoredItemsRequest_delete(request); // This frees ids as well
          deleteCallback.close();
          _undeletedMonitorCallbacks.add(monitorCallback);
          completer.complete();
        }
      }
      return completer.future;
    }

    // Runs monitorTeardown from a microtask, for the paths that end an item
    // from inside the create-response callback. That callback runs
    // synchronously inside the C response-processing stack (runIterate, a
    // blocking service call, or even UA_Client_delete), and issuing a new
    // service call from there re-enters the native client mid-decode. The
    // microtask runs as soon as control returns to the Dart event loop — and
    // must re-check that the client still exists: if the response was
    // delivered during Client.delete()'s native teardown, the client is freed
    // by the time we run and the server side is gone with it.
    void teardownLater() {
      scheduleMicrotask(() {
        if (_client == ffi.nullptr) {
          monitorCallback.close();
          return;
        }
        unawaited(monitorTeardown());
      });
    }

    controller.onCancel = () {
      _activeMonitoredStreams.remove(controller);
      return monitorTeardown();
    };

    controller.onListen = () async {
      // Register this stream so Client.delete() can tear it down if it is still
      // active at delete time. Cleanup paths that bypass onCancel remove it.
      _activeMonitoredStreams[controller] = monitorTeardown;

      // Create our request
      ffi.Pointer<raw.UA_MonitoredItemCreateRequest> monRequest = ua_calloc<raw.UA_MonitoredItemCreateRequest>(
        nodeCount,
      );
      var index = 0;
      for (var entry in nodes.entries) {
        for (var attribute in entry.value) {
          monRequest[index].itemToMonitor.nodeId = entry.key.toRaw();
          monRequest[index].itemToMonitor.attributeId = attribute.value;
          monRequest[index].monitoringModeAsInt = monitoringMode.value;
          monRequest[index].requestedParameters.samplingInterval = samplingInterval.inMicroseconds / 1000.0;
          monRequest[index].requestedParameters.discardOldest = discardOldest;
          monRequest[index].requestedParameters.queueSize = queueSize;
          itemOrder.add((entry.key, attribute));
          index++;
        }
      }

      ffi.Pointer<raw.UA_CreateMonitoredItemsRequest> createRequest = raw.UA_CreateMonitoredItemsRequest_new();
      raw.UA_CreateMonitoredItemsRequest_init(createRequest);
      createRequest.ref.subscriptionId = subscriptionId;
      createRequest.ref.itemsToCreate = monRequest;
      createRequest.ref.itemsToCreateSize = nodeCount;
      if (deliverQuality) {
        // The zeroed default is UA_TIMESTAMPSTORETURN_SOURCE: a DataValue
        // reports the server timestamp too, so ask for both. The request of
        // the value-only stream is left as it has always been.
        createRequest.ref.timestampsToReturnAsInt = raw.UA_TimestampsToReturn.UA_TIMESTAMPSTORETURN_BOTH.value;
      }

      Map<NodeId, DynamicValue> latestValues = {};
      // The status and timestamps of each node's latest Value sample. Only
      // the Value attribute writes here: the other attributes arrive as their
      // own notifications, with their own status and (measured) no source
      // timestamp, and letting them write would clobber a Bad code with the
      // Good of a DisplayName read, and a real timestamp with none.
      Map<NodeId, _SampleQuality> qualities = {};
      // Request-order indexes for which a notification has been processed, and
      // the subset of indexes the server actually created an item for.
      Set<int> seenIndexes = {};
      Set<int> createdIndexes = {};
      void emit() => controller.add(project(latestValues, qualities));

      // Assign our monitor callback pointer, This one stays alive for the duration of the stream
      monitorCallback =
          ffi.NativeCallable<
            ffi.Void Function(
              ffi.Pointer<raw.UA_Client>,
              ffi.Uint32,
              ffi.Pointer<ffi.Void>,
              ffi.Uint32,
              ffi.Pointer<ffi.Void>,
              ffi.Pointer<raw.UA_DataValue>,
            )
          >.isolateLocal((
            ffi.Pointer<raw.UA_Client> client,
            int subId,
            ffi.Pointer<ffi.Void> subContext,
            int monId,
            ffi.Pointer<ffi.Void> monContext,
            ffi.Pointer<raw.UA_DataValue> value,
          ) async {
            // Don't process the data if we are closed
            if (controller.isClosed) {
              _safeErr("Stream closed, data still sent from monitored item $monId");
              return;
            }
            if (value == ffi.nullptr) {
              controller.addError('Failed to read value, nullptr provided');
              return;
            }
            // Read out of the C struct NOW, into Dart locals. The VALUE branch
            // below crosses an async boundary, and this callback "returns" into
            // open62541 at that point — after which `value` points at memory
            // the stack has reclaimed. Every field of it must be captured on
            // this side of the first await or it is read as garbage.
            final flags = value.ref.substitute;
            final sampleStatus = value.ref.status;
            final sampleSourceTicks = value.ref.sourceTimestamp;
            final sampleServerTicks = value.ref.serverTimestamp;
            // Anything but a plain Good, as this stream has always judged it:
            // Uncertain and Good-with-info-bits included.
            final isBadSample = sampleStatus != raw.UA_STATUSCODE_GOOD;

            if (isBadSample && !deliverQuality) {
              // Surface the exact notification status as a typed error so the
              // code is extractable (e.g. Bad_NoCommunication from a
              // data-source node whose backing device is down). The
              // notification's value/timestamps are not delivered.
              controller.addError(UaStatusException(sampleStatus));
              return;
            }
            // Identify the item by its request-time context (request-order index
            // biased by 1 so it is never a NULL pointer). monId is unusable
            // here: it is 0 for notifications the server delivered before the
            // create response was processed.
            final index = monContext.address - 1;
            if (index < 0 || index >= itemOrder.length) {
              stderr.write("Monitored item callback with unknown context (index $index, monId $monId)");
              return;
            }
            final item = itemOrder[index];
            try {
              final nodeId = item.$1;
              final attributeId = item.$2;

              // The quality of a sample belongs to the VALUE: that is the one
              // attribute a DataValue reports. A Bad sample of any other
              // attribute has no field to travel in, so it is reported as the
              // typed error it is on the default path rather than vanish
              // without a trace. It still counts as seen below, so it cannot
              // hold back the Value.
              if (isBadSample && attributeId != AttributeId.UA_ATTRIBUTEID_VALUE) {
                controller.addError(UaStatusException(sampleStatus));
              }

              var reference = latestValues[nodeId] ?? DynamicValue();
              final ref = value.ref.value;

              // A notification without a decodable payload must not enter the
              // switch: every case dereferences the variant's native pointers,
              // and an empty variant (type == NULL) turns that into a
              // process-killing SIGSEGV. Two spec-legal shapes arrive here:
              //  - a sample the server marked Bad, with hasValue CLEAR — its
              //    QUALITY is still news, so it goes on to the shared emit
              //    below with the code recorded (reachable only under
              //    [deliverQuality]; the default path returned above).
              //  - a GOOD sample carrying no value ("the attribute exists and
              //    has no value", Part 4) — hasValue clear, or set around a
              //    null variant. Both leave type == NULL, so both are checked.
              final hasNothingToDecode = (flags & _hasValueFlag) == 0 || ref.type == ffi.nullptr;

              if (hasNothingToDecode) {
                // A GOOD sample without a payload says the Value is empty NOW,
                // so the previously decoded value has to go: left in place it
                // is re-emitted as current while a read of the same node
                // answers null. A sample of another severity keeps it — that
                // is the last-known value [monitoredDataValues] documents. Any
                // other attribute is absent, like the tolerated
                // BadAttributeIdInvalid of readAttribute: nothing is set, and
                // nothing already known is unset.
                if (attributeId == AttributeId.UA_ATTRIBUTEID_VALUE && _isGoodSeverity(sampleStatus)) {
                  reference.value = null;
                }
              } else {
                switch (attributeId) {
                  case AttributeId.UA_ATTRIBUTEID_DESCRIPTION:
                    final description = ref.data.cast<raw.UA_LocalizedText>();
                    reference.description = LocalizedText(description.ref.text.value, description.ref.locale.value);
                  case AttributeId.UA_ATTRIBUTEID_DISPLAYNAME:
                    final displayName = ref.data.cast<raw.UA_LocalizedText>();
                    reference.displayName = LocalizedText(displayName.ref.text.value, displayName.ref.locale.value);
                  case AttributeId.UA_ATTRIBUTEID_DATATYPE:
                    final dataType = ref.data.cast<raw.UA_NodeId>();
                    reference.typeId = dataType.ref.toNodeId();
                  case AttributeId.UA_ATTRIBUTEID_VALUE:
                    // Steal the variant pointer from open62541 so they don't delete it
                    // if we don't do this, the variant will be freed on a flutter async
                    // boundary. f.e. while we fetch the structure of a schema.
                    // because the callback we are currently in "returns" before completing.
                    final source = ua_calloc<raw.UA_Variant>();
                    source.ref = value.ref.value;
                    final variant = raw.UA_Variant_new();
                    raw.UA_Variant_copy(source, variant);
                    ua_calloc.free(source);
                    final data = await _variantToValueAutoSchema(variant.ref, reference.typeId);
                    // Now that we have crossed an async boundary, we need to fetch a new reference. It might have been updated
                    // with a description or other fields while we processed data.
                    reference = latestValues[nodeId] ?? reference;

                    // Update the values of the fields
                    reference.value = data.value;
                    reference.typeId = reference.typeId ?? data.typeId;
                    reference.enumFields = data.enumFields;
                    raw.UA_Variant_delete(variant);
                  case AttributeId.UA_ATTRIBUTEID_DATATYPEDEFINITION:
                    final temporary = OpcUaDynamicValueSerializer.fromDataTypeDefinition(
                      reference.typeId ?? ref.type.ref.typeId.toNodeId(),
                      ref,
                    );
                    reference.value = temporary.value;
                    reference.typeId = reference.typeId ?? temporary.typeId;
                    reference.enumFields = reference.enumFields ?? temporary.enumFields;
                  default:
                    throw 'Unhandled attribute id $attributeId';
                }
              }

              // Recorded AFTER the switch on purpose: the VALUE branch crosses
              // an async boundary, and the quality must describe the value
              // that is emitted with it. An ABSENT status is Good (OPC UA
              // Part 4) and the field reads 0, so the raw status is recorded
              // unconditionally; a sample without a timestamp records none,
              // never the previous sample's.
              if (attributeId == AttributeId.UA_ATTRIBUTEID_VALUE) {
                qualities[nodeId] = _SampleQuality(
                  statusCode: sampleStatus,
                  sourceTimestamp: (flags & _hasSourceTimestampFlag) != 0
                      ? uaDateTimeToDateTime(sampleSourceTicks)
                      : null,
                  serverTimestamp: (flags & _hasServerTimestampFlag) != 0
                      ? uaDateTimeToDateTime(sampleServerTicks)
                      : null,
                );
              }

              // Update the seen indexes after processing
              seenIndexes.add(index);

              latestValues[nodeId] = reference;
              if (controller.isClosed) {
                return; // While processing the data the controller might have been closed
              }
              try {
                if (seenIndexes.length >= nodeCount - descriptionFailureCount) {
                  emit();
                }
              } catch (e) {
                _safeErr("Error adding data: $e");
              }
            } catch (e, stackTrace) {
              // A sample this client cannot decode (a type it has no
              // conversion for, a struct body that does not parse) is the
              // consumer's news, not a log line's: it goes out as an error
              // event. The stream stays open and the subscription stays up,
              // so the next sample is delivered as usual. [isClosed] is
              // checked again here: the VALUE branch above awaited.
              if (!controller.isClosed) {
                controller.addError(e, stackTrace);
              } else {
                _safeErr("Error converting data for: $item to type $DynamicValue: $e");
              }
            }
          });

      // Set all the callbacks to have the same handler function
      for (var i = 0; i < nodeCount; i++) {
        callbacks[i] = monitorCallback.nativeFunction;
      }

      // Define the callback that is invoked when the monitored item is created
      late ffi.NativeCallable<
        ffi.Void Function(
          ffi.Pointer<raw.UA_Client>,
          ffi.Pointer<ffi.Void>,
          ffi.Uint32,
          ffi.Pointer<raw.UA_CreateMonitoredItemsResponse>,
        )
      >
      createCallback;
      createCallback =
          ffi.NativeCallable<
            ffi.Void Function(
              ffi.Pointer<raw.UA_Client>,
              ffi.Pointer<ffi.Void>,
              ffi.Uint32,
              ffi.Pointer<raw.UA_CreateMonitoredItemsResponse>,
            )
          >.isolateLocal((
            ffi.Pointer<raw.UA_Client> client,
            ffi.Pointer<ffi.Void> userdata,
            int requestId,
            ffi.Pointer<raw.UA_CreateMonitoredItemsResponse> response,
          ) {
            // Cleanup the request memory
            raw.UA_CreateMonitoredItemsRequest_delete(createRequest);
            createCallback.close();
            ua_calloc.free(localRequestId);
            // Null it: a non-null value means "create still in flight" to
            // monitorTeardown, which would otherwise read the freed slot and
            // send a Cancel for whatever request id it happens to hold now.
            localRequestId = ffi.nullptr;

            if (cancelledInFlight) {
              // The stream was cancelled while this create was on the wire.
              // Nobody listens any more; the only job left is to undo whatever
              // the server did and release the natives the cancel path could
              // not free (it did not know whether this callback would run).
              if (response != ffi.nullptr && response.ref.responseHeader.serviceResult == raw.UA_STATUSCODE_GOOD) {
                for (var i = 0; i < response.ref.resultsSize; i++) {
                  if (response.ref.results[i].statusCode == raw.UA_STATUSCODE_GOOD) {
                    monIds.add(response.ref.results[i].monitoredItemId);
                  }
                }
              }
              if (monIds.isNotEmpty) {
                // The server ignored the cancel and created the items: delete
                // them for real. monIds is non-empty, so monitorTeardown takes
                // the DeleteMonitoredItems branch (which also closes
                // monitorCallback) and cannot recurse into the cancel branch.
                teardownLater();
              } else {
                // The cancel was honoured (BadRequestCancelledByRequest) or
                // the service failed: the C layer already dropped any local
                // items and the server holds nothing. Just release.
                scheduleMicrotask(() => monitorCallback.close());
              }
              return;
            }

            inactivitySub = config.subscriptionInactivityStream.listen((inactiveSubscriptionId) {
              if (controller.isClosed) {
                inactivitySub?.cancel();
                return;
              }
              if (inactiveSubscriptionId == subscriptionId) {
                controller.addError(Inactivity());
              }
            });
            deletedSub = config.subscriptionDeletedStream.listen((deletedSubscriptionId) {
              if (controller.isClosed) {
                deletedSub?.cancel();
                return;
              }
              if (deletedSubscriptionId == subscriptionId) {
                controller.addError(SubscriptionDeleted(deletedSubscriptionId));
              }
            });
            stateSub = config.stateStream.listen((state) {
              if (controller.isClosed) {
                stateSub?.cancel();
                return;
              }
              if (state.channelState == SecureChannelState.UA_SECURECHANNELSTATE_CLOSED) {
                controller.addError(SecureChannelClosed());
              }
            });
            // The release for a create that produced no item at all: nothing
            // exists server-side, so monitorCallback can go at once and there
            // is no teardown for onCancel to run.
            cleanup() {
              _activeMonitoredStreams.remove(controller);
              controller.onCancel = () {}; // Don't invoke the real close callback
              releaseConfigListeners();
              monitorCallback.close();
              controller.close();
            }

            if (response == ffi.nullptr) {
              controller.addError('ffi pointer is null');
              cleanup();
              return;
            } else if (response.ref.responseHeader.serviceResult != raw.UA_STATUSCODE_GOOD) {
              // Service-level status FIRST: a failed service answers with zero
              // results, and checking resultsSize first used to mask the real
              // failure as a misleading "No results" error.
              controller.addError(UaStatusException(response.ref.responseHeader.serviceResult));
              cleanup();
              return;
            } else if (response.ref.resultsSize == 0) {
              controller.addError('No results for create monitored item');
              cleanup();
              return;
            }

            assert(response.ref.resultsSize == nodeCount);
            int index = 0;
            Map<(NodeId, AttributeId), int> failures = {};
            for (var node in nodes.keys) {
              for (var attribute in nodes[node]!) {
                if (response.ref.results[index].statusCode == raw.UA_STATUSCODE_GOOD) {
                  monIds.add(response.ref.results[index].monitoredItemId);
                  createdIndexes.add(index);
                } else {
                  // Allow for the description attribute to be missing
                  if (response.ref.results[index].statusCode != raw.UA_STATUSCODE_BADATTRIBUTEIDINVALID &&
                      attribute != AttributeId.UA_ATTRIBUTEID_DESCRIPTION) {
                    failures[(node, attribute)] = response.ref.results[index].statusCode;
                  } else {
                    descriptionFailureCount++;
                  }
                }
                index++;
              }
            }
            if (failures.isNotEmpty) {
              controller.addError(MonitoredItemsRefused(failures));
              // This is the path a caller that rebuilds a refused item (a
              // hard BadNodeIdUnknown, forever, on a backoff ladder) walks on
              // every attempt, so it must leave nothing behind. It used to
              // just close the controller and let the done event's onCancel
              // run monitorTeardown — which, with no item created, took the
              // "create still in flight" branch against the freed request-id
              // slot and never closed monitorCallback.
              if (monIds.isEmpty) {
                // Every item was refused: identical to the refusals above.
                cleanup();
              } else {
                // Some items WERE created and must be deleted again — through
                // monitorTeardown, deferred because this runs inside the C
                // stack. Deregister now; the teardown is ours to run, not the
                // done event's, and it releases the listeners.
                _activeMonitoredStreams.remove(controller);
                controller.onCancel = () {};
                controller.close();
                teardownLater();
              }
              return;
            }

            // The initial notifications can have arrived before this response
            // (that is the race the context-based identity exists for). If items
            // failed with the tolerated description-attribute error, the gate in
            // the data callback compared against the wrong expected count while
            // descriptionFailureCount was still 0 — re-check it now, because the
            // already-delivered static attributes are never notified again.
            if (descriptionFailureCount > 0 &&
                seenIndexes.length >= nodeCount - descriptionFailureCount &&
                !controller.isClosed) {
              emit();
            }

            // Backfill initial notifications a server never published. With
            // item identity carried in the monitored-item context the
            // early-notification race no longer loses values, so this only
            // triggers for servers that genuinely fail to send an initial
            // notification for a created item; without it the seenIndexes gate
            // would never be satisfied and the stream would never emit.
            Future.delayed(const Duration(seconds: 1), () async {
              if (controller.isClosed || _client == ffi.nullptr) return;
              final expectedCount = nodeCount - descriptionFailureCount;
              if (seenIndexes.length >= expectedCount) return;

              final missingAttrs = <NodeId, List<AttributeId>>{};
              for (final index in createdIndexes) {
                if (!seenIndexes.contains(index)) {
                  final item = itemOrder[index];
                  missingAttrs.putIfAbsent(item.$1, () => []).add(item.$2);
                }
              }
              if (missingAttrs.isEmpty) return;

              try {
                final results = await readAttribute(missingAttrs);
                if (controller.isClosed) return;
                if (seenIndexes.length >= expectedCount) return;
                for (final entry in results.entries) {
                  final existing = latestValues[entry.key] ?? DynamicValue();
                  existing.description ??= entry.value.description;
                  existing.displayName ??= entry.value.displayName;
                  existing.typeId ??= entry.value.typeId;
                  existing.value ??= entry.value.value;
                  existing.enumFields ??= entry.value.enumFields;
                  existing.extObjEncodingId ??= entry.value.extObjEncodingId;
                  latestValues[entry.key] = existing;
                }
                seenIndexes.addAll(createdIndexes);
                if (!controller.isClosed && seenIndexes.length >= expectedCount) {
                  emit();
                }
              } catch (e) {
                _safeErr('Failed to backfill dropped initial notifications: $e');
              }
            });
          });
      localRequestId = ua_calloc<ffi.Uint32>();
      // Per-item contexts: the request-order index biased by 1 so no entry is a
      // NULL pointer. open62541 never dereferences these — it copies each entry
      // into its monitored item during the call below and hands it back verbatim
      // to the data callback, so the array itself can be freed right after.
      final contexts = ua_calloc<ffi.Pointer<ffi.Void>>(nodeCount);
      for (var i = 0; i < nodeCount; i++) {
        contexts[i] = ffi.Pointer.fromAddress(i + 1);
      }
      final statusCode = raw.UA_Client_MonitoredItems_createDataChanges_async(
        _client,
        createRequest.ref,
        contexts,
        callbacks,
        ffi.nullptr,
        createCallback.nativeFunction,
        ffi.nullptr,
        localRequestId,
      );
      ua_calloc.free(contexts);
      // Same for the callback array: open62541 copies each entry into its
      // monitored item during the call above and never touches the array
      // again, so it does not have to live until teardown.
      ua_calloc.free(callbacks);
      if (statusCode != raw.UA_STATUSCODE_GOOD) {
        raw.UA_CreateMonitoredItemsRequest_delete(createRequest);
        ua_calloc.free(localRequestId);
        localRequestId = ffi.nullptr;
        monitorCallback.close();
        createCallback.close();
        // Typed, like the async response path: the exact status code (e.g.
        // BadSubscriptionIdInvalid, refused client-side before anything is
        // sent) stays programmatically extractable.
        controller.addError(UaStatusException(statusCode));
        // Don't invoke the real onCancel — resources are already freed above.
        _activeMonitoredStreams.remove(controller);
        controller.onCancel = () {};
      }
    };

    return controller.stream;
  }

  @override
  Stream<DynamicValue> monitor(
    NodeId nodeId,
    int subscriptionId, {
    MonitoringMode monitoringMode = MonitoringMode.UA_MONITORINGMODE_REPORTING,
    Duration samplingInterval = const Duration(milliseconds: 100),
    bool discardOldest = true,
    int queueSize = 1,
  }) {
    final controller = StreamController<DynamicValue>();
    final stream = monitoredItems(
      {
        nodeId: [
          AttributeId.UA_ATTRIBUTEID_DATATYPE,
          AttributeId.UA_ATTRIBUTEID_VALUE,
          AttributeId.UA_ATTRIBUTEID_DESCRIPTION,
          AttributeId.UA_ATTRIBUTEID_DISPLAYNAME,
        ],
      },
      subscriptionId,
      monitoringMode: monitoringMode,
      samplingInterval: samplingInterval,
      discardOldest: discardOldest,
      queueSize: queueSize,
    );
    final subscription = stream.listen((event) => controller.add(event.values.first));
    subscription.onError((error) => controller.addError(error));
    controller.onCancel = () {
      subscription.cancel();
    };
    subscription.onDone(() {
      controller.close();
    });
    return controller.stream;
  }

  @override
  Stream<DataValue> monitorDataValue(
    NodeId nodeId,
    int subscriptionId, {
    MonitoringMode monitoringMode = MonitoringMode.UA_MONITORINGMODE_REPORTING,
    Duration samplingInterval = const Duration(milliseconds: 100),
    bool discardOldest = true,
    int queueSize = 1,
  }) {
    final controller = StreamController<DataValue>();
    final stream = monitoredDataValues(
      {
        nodeId: [
          AttributeId.UA_ATTRIBUTEID_DATATYPE,
          AttributeId.UA_ATTRIBUTEID_VALUE,
          AttributeId.UA_ATTRIBUTEID_DESCRIPTION,
          AttributeId.UA_ATTRIBUTEID_DISPLAYNAME,
        ],
      },
      subscriptionId,
      monitoringMode: monitoringMode,
      samplingInterval: samplingInterval,
      discardOldest: discardOldest,
      queueSize: queueSize,
    );
    final subscription = stream.listen((event) => controller.add(event.values.first));
    subscription.onError((error) => controller.addError(error));
    controller.onCancel = () {
      subscription.cancel();
    };
    subscription.onDone(() {
      controller.close();
    });
    return controller.stream;
  }

  @override
  Future<List<DynamicValue>> call(NodeId objectId, NodeId methodId, Iterable<DynamicValue> args) async {
    final completer = Completer<List<DynamicValue>>();
    final callbackInner =
        ffi.NativeCallable<
          ffi.Void Function(
            ffi.Pointer<raw.UA_Client>,
            ffi.Pointer<ffi.Void>,
            ffi.Uint32,
            ffi.Pointer<raw.UA_CallResponse>,
          )
        >.isolateLocal((
          ffi.Pointer<raw.UA_Client> client,
          ffi.Pointer<ffi.Void> userdata,
          int requestId,
          ffi.Pointer<raw.UA_CallResponse> cr,
        ) async {
          try {
            final ref = cr.ref;
            // Check the service-level status FIRST: a failed service (session
            // torn down, secure channel closed, request timeout, ...) answers
            // with zero results, and checking resultsSize first used to mask
            // the real failure as a misleading "No results" error.
            if (ref.responseHeader.serviceResult != raw.UA_STATUSCODE_GOOD) {
              return completer.completeError(UaStatusException(ref.responseHeader.serviceResult), StackTrace.current);
            }
            if (ref.resultsSize == 0) {
              return completer.completeError("No results for call to $objectId $methodId", StackTrace.current);
            }
            if (ref.resultsSize > 1) {
              return completer.completeError(
                "Unsupported, multiple results for call to $objectId $methodId",
                StackTrace.current,
              );
            }
            final results = ref.results.ref;
            if (results.statusCode != raw.UA_STATUSCODE_GOOD) {
              return completer.completeError(
                "Results error on call to $objectId $methodId failed with ${statusCodeToString(results.statusCode)}",
                StackTrace.current,
              );
            }
            if (results.outputArgumentsSize == 0) {
              completer.complete([]);
            } else {
              // Deep-copy every output variant SYNCHRONOUSLY before the first
              // await: open62541 frees the whole CallResponse the moment this
              // native callback returns, and this closure is async — after an
              // await it resumes with `results` pointing at freed memory.
              // (This was the "only the first output argument reaches the
              // caller" bug: output[0] of a simple type decoded in the
              // synchronous prefix, every later output read garbage.)
              final copies = <ffi.Pointer<raw.UA_Variant>>[];
              for (var i = 0; i < results.outputArgumentsSize; i++) {
                final copy = raw.UA_Variant_new();
                final copyStatus = raw.UA_Variant_copy(results.outputArguments + i, copy);
                if (copyStatus != raw.UA_STATUSCODE_GOOD) {
                  for (final c in copies) {
                    raw.UA_Variant_delete(c);
                  }
                  raw.UA_Variant_delete(copy);
                  return completer.completeError(
                    "Failed to copy output argument $i of call to $objectId $methodId: "
                    "${statusCodeToString(copyStatus)}",
                    StackTrace.current,
                  );
                }
                copies.add(copy);
              }
              try {
                final result = <DynamicValue>[];
                for (final copy in copies) {
                  // May await (schema fetch for custom structs) — safe now,
                  // we own the copies.
                  result.add(await _variantToValueAutoSchema(copy.ref));
                }
                completer.complete(result);
              } finally {
                for (final c in copies) {
                  raw.UA_Variant_delete(c);
                }
              }
            }
          } catch (e) {
            _safeErr("Error calling callback: $e");
            completer.completeError(e, StackTrace.current);
          }
        });

    // open62541 encodes the request before the call returns and keeps nothing
    // of it, so the argument array, the variants in it and the buffers behind
    // string NodeIds are scratch for the call. The arena releases them however
    // it ends, also when an argument cannot be encoded.
    final int statusCode;
    try {
      statusCode = using((arena) {
        final values = args.toList();
        final inputArgs = arena<raw.UA_Variant>(values.length);
        for (var i = 0; i < values.length; i++) {
          // A shallow copy: the payload stays the variant's, freed with it.
          inputArgs[i] = arena.using(valueToVariant(values[i]), raw.UA_Variant_delete).ref;
        }
        return raw.UA_Client_call_async(
          _client,
          objectId.toRaw(allocator: arena),
          methodId.toRaw(allocator: arena),
          values.length,
          inputArgs,
          callbackInner.nativeFunction,
          ffi.nullptr, // todo set context?
          ffi.nullptr,
        );
      }, ua_calloc);
    } catch (_) {
      callbackInner.close();
      rethrow;
    }
    if (statusCode != raw.UA_STATUSCODE_GOOD) {
      callbackInner.close();
      throw 'Unable to call method: $statusCode ${statusCodeToString(statusCode)}';
    }
    // The native callback fires exactly once per call (response, error or
    // cancel). Release its trampoline afterwards — leaking one per call kept
    // the isolate (and any embedding process, e.g. a CLI) alive forever.
    completer.future.whenComplete(callbackInner.close).ignore();
    return completer.future;
  }

  /// Fetches the DataTypeDefinition of [nodeIdType] and, recursively, of
  /// every structured type its fields use, as a [Schema] keyed by DataType id.
  ///
  /// The definitions are the server's word. One whose field is of the type
  /// being defined, directly or through other types (A → B → A), would be
  /// fetched forever, one readAttribute per level; such a definition is
  /// invalid (a structure cannot contain itself by value) and is refused with
  /// a [DataTypeDefinitionCycle] naming the types on the cycle. The nesting is
  /// also capped at [DataTypeDefinitionTooDeep.limit] levels, the bound
  /// open62541's binary decoder uses. Either way the read that needed the
  /// schema fails and the client stays usable.
  Future<Schema> buildSchema(NodeId nodeIdType) => _buildSchema(nodeIdType, const []);

  /// [resolving] is the chain of DataType ids whose definitions are being
  /// built, outermost first: the types whose fields led here.
  Future<Schema> _buildSchema(NodeId nodeIdType, List<NodeId> resolving) async {
    final path = [...resolving, nodeIdType];
    if (resolving.contains(nodeIdType)) {
      throw DataTypeDefinitionCycle(path.sublist(resolving.indexOf(nodeIdType)));
    }
    if (resolving.length >= DataTypeDefinitionTooDeep.limit) {
      throw DataTypeDefinitionTooDeep(path);
    }
    var map = Schema();
    final read = await readAttribute({
      nodeIdType: [AttributeId.UA_ATTRIBUTEID_DATATYPEDEFINITION],
    });
    if (read.isEmpty) {
      // The server exposes no DataTypeDefinition for this type — it is a simple
      // type (or a vendor alias of one, e.g. TwinCAT's STRING at a custom
      // NodeId), not a struct/enum. Return an empty schema; the value then
      // decodes by its wire type.
      return map;
    }
    map[nodeIdType] = read.values.first;
    final val = map[nodeIdType]!;
    if (val.typeId == NodeId.structureDefinition) {
      val.typeId =
          nodeIdType; // TODO: Inside the read enum typeids are overwritten as int32. This is a mix and needs to be cleaned up
    }
    // Now that the real DataType NodeId is known, restore any field metadata
    // (descriptions / display names) the DataTypeDefinition could not carry but
    // an in-process server registered locally.
    OpcUaDynamicValueSerializer.overlayLocalFieldMetadata(nodeIdType, val);
    if (val.isObject) {
      for (var entry in val.entries) {
        if (nodeIdToPayloadType(entry.value.typeId) == null) {
          final temporary = await _buildSchema(entry.value.typeId!, path);
          map.addAll(temporary);
          if (val[entry.value.name].isArray) {
            // todo: only supports one level of array
            for (var i = 0; i < val[entry.value.name].asArray.length; i++) {
              val[entry.value.name][i] = map[entry.value.typeId]!;
            }
          } else {
            val[entry.value.name] = map[entry.value.typeId]!;
          }
        }
      }
    }
    return map;
  }

  /// The default of [schemaCacheSize].
  static const defaultSchemaCacheSize = 4096;

  /// The most entries [defs] holds: a server chooses the DataType ids it
  /// serves, so without a bound every distinct one would stay for the life
  /// of the client. When a new definition would go past it the cache is
  /// emptied and refilled on demand. A single type whose definitions alone
  /// exceed it is kept anyway, until the next one arrives.
  final int schemaCacheSize;

  /// The DataType definitions fetched so far, by DataType id (and by
  /// DefaultBinary encoding id once resolved); at most [schemaCacheSize].
  Schema defs = {};

  /// Adds [schemas] to [defs], emptying both caches first if they would
  /// outgrow [schemaCacheSize]. A decode in flight holds its own definitions
  /// (see [_variantToValueAutoSchema]), so emptying never takes them away.
  void _cacheSchemas(Schema schemas) {
    if (defs.length + schemas.length > schemaCacheSize || _dataTypeByEncoding.length >= schemaCacheSize) {
      defs.clear();
      _dataTypeByEncoding.clear();
    }
    defs.addAll(schemas);
  }

  Future<DynamicValue> _variantToValueAutoSchema(raw.UA_Variant data, [NodeId? dataTypeId]) async {
    // An empty variant (type == NULL) has no payload and no type to probe a
    // schema from — the deref on the next line would be a native SIGSEGV, not
    // a catchable error. Answer the same null DynamicValue that variantToValue
    // produces for a variant without data.
    if (data.type == ffi.nullptr) {
      return DynamicValue();
    }
    if (isNativeStructKind(data.type.ref.typeKind)) {
      // A structure open62541 knows (every NS0 DataType) came decoded into the
      // native struct: variantToValue walks the type's member table, which
      // also names the fields and the enum values. No DataTypeDefinition to
      // fetch, and buildSchema would fail on a member such as a LocalizedText
      // that has no definition of its own.
      return variantToValue(data, defs: defs);
    }
    // What this call fetched, which a concurrent call emptying the cache
    // while this one awaits must not take from under the decode below.
    final fetched = Schema();
    bool known(NodeId id) => defs.containsKey(id) || fetched.containsKey(id);
    Future<void> fetch(NodeId id) async {
      final schema = await buildSchema(id);
      fetched.addAll(schema);
      _cacheSchemas(schema);
    }

    if (dataTypeId != null && nodeIdToPayloadType(dataTypeId) == null && !known(dataTypeId)) {
      await fetch(dataTypeId);
    }
    final isExtensionObject = data.type.ref.typeKind == raw.UA_DataTypeKind.UA_DATATYPEKIND_EXTENSIONOBJECT;
    if (isExtensionObject && (dataTypeId == null || !known(dataTypeId))) {
      // No usable DataType at hand: none (readValue, call outputs) or one
      // without a definition (BaseDataType i=24, as a relay serves a value
      // under). The ExtensionObject's typeId is the type's DefaultBinary
      // encoding id, a DataTypeEncoding object, not the DataType. Resolve it
      // the way a browser does, by its inverse HasEncoding reference; a
      // server that encodes under the DataType id has no such reference, and
      // the wire id is then tried as the DataType itself.
      final ext = data.data.cast<raw.UA_ExtensionObject>();
      final encodingId = ext.ref.content.encoded.typeId.toNodeId();
      var resolved = _dataTypeByEncoding[encodingId];
      if (resolved != null && !known(resolved)) {
        await fetch(resolved);
      }
      if (resolved == null) {
        final resolution = await _resolveEncoding(encodingId);
        resolved = resolution.dataType;
        if (resolved == null && resolution.nodeExists && !known(encodingId)) {
          await fetch(encodingId);
        }
        if (resolved == null && known(encodingId)) {
          resolved = encodingId;
        }
        if (resolved != null && !known(resolved)) {
          await fetch(resolved);
        }
        if (resolved != null && known(resolved)) {
          _dataTypeByEncoding[encodingId] = resolved;
        } else {
          resolved = null;
        }
      }
      if (resolved == null) {
        // Nothing in the address space describes this ExtensionObject: keep
        // its body with the wire id rather than fail the read.
        return decodeExtensionObjectsOpaque(data, defs: fetched.isEmpty ? defs : {...defs, ...fetched});
      }
      // Alias the schema under the encoding id, which is what a nested
      // ExtensionObject is looked up by.
      if (!known(encodingId)) {
        // Held in [fetched] too: adding the alias may empty the cache.
        final schema = fetched[resolved] ??= defs[resolved]!;
        fetched[encodingId] = schema;
        _cacheSchemas({encodingId: schema});
      }
      dataTypeId = resolved;
    }
    final retValue = variantToValue(data, defs: fetched.isEmpty ? defs : {...defs, ...fetched}, dataTypeId: dataTypeId);
    return retValue;
  }

  /// DataType id per DefaultBinary encoding id resolved so far.
  final Map<NodeId, NodeId> _dataTypeByEncoding = {};

  /// Resolves a DefaultBinary encoding id to its DataType: the target of
  /// the encoding object's inverse HasEncoding reference.
  ///
  /// `dataType` is null when the node has no such reference or does not
  /// exist (`nodeExists` tells which; a server that encodes under the
  /// DataType id publishes no encoding object). A Browse that fails for any
  /// other reason (the service, the connection) is thrown, never taken for
  /// "no such node".
  Future<({NodeId? dataType, bool nodeExists})> _resolveEncoding(NodeId encodingId) async {
    try {
      final refs = await browse(
        encodingId,
        direction: raw.UA_BrowseDirection.UA_BROWSEDIRECTION_INVERSE.value,
        referenceTypeId: NodeId.hasEncoding,
        includeSubtypes: false,
        nodeClassMask: NodeClass.UA_NODECLASS_DATATYPE.value,
      );
      return (dataType: refs.isEmpty ? null : refs.first.nodeId, nodeExists: true);
    } on _BrowseResultError catch (e) {
      const noSuchNode = {
        raw.UA_STATUSCODE_BADNODEIDUNKNOWN,
        raw.UA_STATUSCODE_BADNODEIDINVALID,
        raw.UA_STATUSCODE_BADNOTFOUND,
      };
      if (noSuchNode.contains(e.statusCode)) {
        return (dataType: null, nodeExists: false);
      }
      rethrow;
    }
  }

  // ignore: unused_element
  ffi.Pointer<raw.UA_DataType> _findDataType(NodeId typeId) {
    final nodeId = ua_calloc<raw.UA_NodeId>();
    nodeId.ref = typeId.toRaw();
    final ret = raw.UA_Client_findDataType(_client, nodeId);
    ua_calloc.free(nodeId);
    return ret;
  }

  void disconnect() {
    final statusCode = raw.UA_Client_disconnect(_client);
    if (statusCode != raw.UA_STATUSCODE_GOOD) {
      throw 'Unable to disconnect: $statusCode ${statusCodeToString(statusCode)}';
    }
  }

  @override
  Future<void> delete() async {
    // Tear down any monitored-item streams that are still active BEFORE the
    // native client is freed. Otherwise an in-flight Publish data-change
    // notification would be delivered into the monitor's NativeCallable against
    // freed native memory, hard-crashing the Dart VM (SEGV / SEGV_ACCERR).
    // This mirrors the isolate client's DeleteMessage handler, which cancels
    // every active stream before calling client.delete(). The native monitored
    // items delete is async, so we run the teardowns while _client is still
    // valid and the run_iterate loop (the caller's, or the keepConnected pump
    // below) is still processing responses -- hence this runs before the pump
    // is stopped.
    final teardowns = <Future<void>>[];
    for (final entry in _activeMonitoredStreams.entries.toList()) {
      final controller = entry.key;
      final teardown = entry.value;
      // We invoke the teardown directly here, so neutralise the stream's
      // onCancel to avoid running the native teardown a second time when the
      // controller is closed below.
      controller.onCancel = () {};
      teardowns.add(teardown().whenComplete(controller.close));
    }
    _activeMonitoredStreams.clear();
    // The native monitored-items delete completes via a callback dispatched
    // inside run_iterate, so we must keep pumping until the teardowns finish.
    // We drive it ourselves rather than relying on the caller's loop, which may
    // already have stopped (e.g. a dispose that halts its pump before delete,
    // or a server crash). Bounded so a dead connection can never hang delete():
    // if the peer is gone the native delete cannot be acked, and UA_Client_delete
    // below tears the subscriptions down natively anyway.
    if (teardowns.isNotEmpty) {
      var done = false;
      unawaited(Future.wait(teardowns).whenComplete(() => done = true));
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (!done && _client != ffi.nullptr && DateTime.now().isBefore(deadline)) {
        raw.UA_Client_run_iterate(_client, 5);
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    // Stop the auto-reconnect supervisor/pump before tearing down the client.
    _keepConnected = false;
    if (!_reconnectController.isClosed) {
      await _reconnectController.close();
    }
    ffi.Pointer<raw.UA_Client> client = _client;
    _client = ffi.nullptr;
    await Future.delayed(Duration(milliseconds: 10));
    raw.UA_Client_delete(client);
    // The native client is freed, and with it every monitored item that could
    // still invoke one of these callbacks. Only now can they be closed.
    for (final callback in _undeletedMonitorCallbacks) {
      callback.close();
    }
    _undeletedMonitorCallbacks.clear();
    // Client_delete calls client config state callbacks
    // Need to close the config after deleting the client
    // s.t. the native callbacks are not closed when called
    await _clientConfig.close();
  }

  late ffi.Pointer<raw.UA_Client> _client;
  late final ClientConfig _clientConfig;
  final List<ffi.NativeCallable> _subscriptionDeleteCallbacks = [];

  // Monitor callbacks of items whose DeleteMonitoredItems request could not be
  // sent (dead channel). The native client still holds those items and can
  // invoke the callbacks again after a reconnect, so they stay open until
  // delete() has freed the native client.
  final List<ffi.NativeCallable> _undeletedMonitorCallbacks = [];

  // Registry of active monitored-item streams keyed by their StreamController,
  // mapped to their native teardown function. Populated on onListen, removed on
  // cancel/cleanup, and drained by delete() so that no monitored-item callback
  // can fire into freed native memory after UA_Client_delete.
  final Map<StreamController, Future<void> Function()> _activeMonitoredStreams = {};

  // Auto-reconnect (opt-in via [keepConnected]) state.
  bool _keepConnected = false;

  /// Bumped by every [keepConnected] call; the pump and supervisor it started
  /// stop when a later call has moved it on.
  int _keepConnectedGeneration = 0;
  final StreamController<void> _reconnectController = StreamController<void>.broadcast();
}
