import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:math' show max;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:logging/logging.dart';

import 'common.dart';
import 'extensions.dart';
import 'node_id.dart';
import 'security.dart';
import 'third_party/open62541.g.dart' as raw;
import 'types/errors.dart';
import 'ua_allocation.dart';

/// What a client presented to activate a session, handed to
/// [AccessControl.activateSession].
///
/// By then open62541 has selected the endpoint and token policy, decrypted
/// the password and, for an X.509 token, checked its signature and verified
/// the certificate against the server's trust list.
final class SessionActivation {
  SessionActivation({
    required this.sessionId,
    required this.tokenType,
    this.username,
    this.password,
    this.userCertificate,
    this.clientCertificate,
    this.clientApplicationUri,
    required this.securityMode,
    required this.securityPolicyUri,
    this.reactivation = false,
    this.previousContext,
    this.remoteAddress,
  });

  final NodeId sessionId;

  /// Anonymous, username or certificate.
  final UserTokenType tokenType;

  /// The user name of a username token.
  final String? username;

  /// The plaintext password of a username token. It is zeroed once
  /// [AccessControl.activateSession] returns: copy it to keep it.
  final Uint8List? password;

  /// The certificate of a certificate token, already verified against the
  /// server's trust list.
  final Certificate? userCertificate;

  /// The client's application instance certificate from the SecureChannel,
  /// `null` on a SecurityPolicy#None channel.
  final Certificate? clientCertificate;

  /// The `applicationUri` of the client's ApplicationDescription. On a
  /// secured channel the server has checked it against [clientCertificate].
  final String? clientApplicationUri;

  /// The mode and policy of the endpoint the session activates on.
  final MessageSecurityMode securityMode;
  final String securityPolicyUri;

  /// Whether the session was activated before: the client re-activates it,
  /// typically on a new SecureChannel after a connection loss. open62541
  /// refuses a change of identity on re-activation before asking.
  final bool reactivation;

  /// The context [AccessControl.activateSession] returned for the previous
  /// activation, when [reactivation].
  final Object? previousContext;

  /// The numeric address (without port) of the client's TCP connection.
  final String? remoteAddress;
}

/// A session [AccessControl.activateSession] accepted.
final class ActiveSession {
  const ActiveSession(this.sessionId, this.context, this.activation);

  final NodeId sessionId;

  /// What [AccessControl.activateSession] returned.
  final Object? context;

  /// The latest activation (its password already zeroed).
  final SessionActivation activation;
}

/// The largest access tag (`accessTag:`, `Server.setAccessTag`).
const maxAccessTag = 0x3FFFFFFFFFFFFFFF;

/// The node context that stores access [tag]: odd, so it never equals a
/// pointer open62541 keeps in the same place (an aligned address is even),
/// and null for no tag.
ffi.Pointer<ffi.Void> accessTagContext(int tag) => ffi.Pointer.fromAddress(tag == 0 ? 0 : (tag << 1) | 1);

/// Whether the node context at [address] is an access tag or none, rather
/// than open62541's own (a `UA_Subscription*` on the SubscriptionDiagnostics
/// variables).
bool isAccessTagContext(int address) => address == 0 || address & 1 == 1;

int _accessTagOf(int address) => address & 1 == 1 ? address >>> 1 : 0;

/// A node an [AccessControl] hook decides about. The library reuses the
/// object for every call: it is valid only during the hook it is passed to.
abstract interface class NodeRef {
  /// The node's access tag (`accessTag:` of the add* methods,
  /// `Server.setAccessTag`); `0` for a node without one, such as every NS0
  /// node and every node whose context open62541 uses itself.
  int get tag;

  /// The node's id, decoded on first use.
  NodeId get nodeId;
}

/// Who may open a session on a `Server` and what each session may do: the
/// open62541 access-control plugin, implemented in Dart (`Server(accessControl:)`).
///
/// [activateSession] decides who gets in and returns the session's
/// context, an object every later decision about that session receives.
/// The other hooks decide per node. Each defaults to open62541's own
/// default plugin, which allows everything, so an implementation overrides
/// only what it restricts.
///
/// The hooks restrict, they never grant: open62541 ANDs [userAccessLevel]
/// with the node's AccessLevel and [userRightsMask] with its WriteMask, so a
/// read-only node stays read-only whatever they answer. They apply to client
/// sessions only: the host's own `Server.read`, `Server.write`,
/// `Server.addVariableNode` and the rest run as open62541's admin session,
/// which is never asked. A request without a session this access control
/// activated (a monitored item of a subscription whose session is gone) is
/// denied without asking.
///
/// Every hook runs synchronously inside `Server.runIterate`, on the isolate
/// that pumps the server, while the whole server waits: it must not block
/// and cannot await. The node hooks run on every Read and Write of a value,
/// every Browse and every sample of a monitored item, so they should be a
/// lookup on [NodeRef.tag] and the context rather than work on
/// [NodeRef.nodeId]. A hook that throws denies: the session is refused, the
/// access level and rights are 0, the permission false. The first exception
/// of each hook is logged on the `open62541.Server` logger
/// (package:logging), later ones are not.
abstract class AccessControl {
  const AccessControl();

  /// The user identity tokens the endpoints offer, one token policy per
  /// type. A certificate token needs a server with a `trustList`, which
  /// verifies the user certificates; an issued token is not supported.
  Set<UserTokenType> get userTokenTypes;

  /// Accepts a session activation by returning the session's context (any
  /// object, also `null`), or refuses it by throwing a [UaStatusException]
  /// with the status the client receives (`BadUserAccessDenied`,
  /// `BadIdentityTokenRejected`, ...); anything else thrown refuses with
  /// `BadUserAccessDenied`.
  Object? activateSession(SessionActivation activation);

  /// The session ended: closed by the client, timed out, closed by
  /// `Server.closeSession`, or the server was deleted.
  void closeSession(ActiveSession session) {}

  /// The session's access level for a variable (`UserAccessLevel`), ANDed
  /// with its AccessLevel attribute: the CurrentRead (`0x01`) and
  /// CurrentWrite (`0x02`) bits gate reads, monitored items and writes of
  /// its value, and the HistoryRead bit (`0x04`) a HistoryRead of it; what
  /// they do not allow is `BadUserAccessDenied`. Answer `0xFF` for full
  /// access: `0x03` would deny every HistoryRead.
  int userAccessLevel(Object? context, NodeRef node) => 0xFF;

  /// The session's write mask for the node's attributes, ANDed with its
  /// WriteMask.
  int userRightsMask(Object? context, NodeRef node) => 0xFFFFFFFF;

  /// The UserExecutable attribute the session reads for a method. It does
  /// not gate calls; [userExecutableOnObject] does.
  bool userExecutable(Object? context, NodeRef method) => true;

  /// Whether the session may call [method] on [object]; a refused call
  /// answers `BadUserAccessDenied`.
  bool userExecutableOnObject(Object? context, NodeRef method, NodeRef object) => true;

  /// Whether the session may browse the node and read its attributes other
  /// than the Value: a refused Browse of it is `BadUserAccessDenied`,
  /// TranslateBrowsePathsToNodeIds neither passes through nor resolves to
  /// it (`src/server/ua_services_view.c`), and a Read of any attribute but
  /// Value and RolePermissions is `BadUserAccessDenied`
  /// (`src/server/ua_services_attribute.c`; the Value is
  /// [userAccessLevel]'s). open62541 asks only about the node a Browse
  /// starts from: the node still appears among its parent's references, so
  /// this hides what is below a node, not the node itself.
  bool allowBrowse(Object? context, NodeRef node) => true;

  /// Whether the session may add a node under [parent] (AddNodes). Asked
  /// only on a server with `allowClientNodeManagement: true`; otherwise the
  /// server refuses node management to every client.
  bool allowAddNode(Object? context, NodeRef parent) => true;

  /// Whether the session may add a reference from [source] (AddReferences),
  /// with `allowClientNodeManagement: true`.
  bool allowAddReference(Object? context, NodeRef source) => true;

  /// Whether the session may delete [node] (DeleteNodes), with
  /// `allowClientNodeManagement: true`.
  bool allowDeleteNode(Object? context, NodeRef node) => true;

  /// Whether the session may delete a reference of [source]
  /// (DeleteReferences), with `allowClientNodeManagement: true`.
  bool allowDeleteReference(Object? context, NodeRef source) => true;

  /// Whether the session [to] may take over a subscription of [from]
  /// (TransferSubscriptions). [from] is `null` when the subscription's
  /// session is gone: a session that times out leaves its subscriptions
  /// for another to take over, and [closeSession] has already run for it.
  /// A session closed by the client or by `Server.closeSession` takes its
  /// subscriptions with it, so there is nothing to transfer.
  ///
  /// The default is open62541's: never from a session that is gone; between
  /// sessions of the same user (user name or user certificate); between
  /// anonymous sessions only when both are on secured channels and announce
  /// the same client ApplicationUri.
  bool allowTransferSubscription(ActiveSession? from, ActiveSession to) {
    if (from == null) return false;
    final a = from.activation;
    final b = to.activation;
    if (a.tokenType != b.tokenType) return false;
    return switch (a.tokenType) {
      UserTokenType.UA_USERTOKENTYPE_USERNAME =>
        a.username != null && a.username!.isNotEmpty && a.username == b.username,
      UserTokenType.UA_USERTOKENTYPE_CERTIFICATE => a.userCertificate != null && a.userCertificate == b.userCertificate,
      UserTokenType.UA_USERTOKENTYPE_ANONYMOUS =>
        a.securityPolicyUri != SecurityPolicy.none.uri &&
            b.securityPolicyUri != SecurityPolicy.none.uri &&
            (a.clientApplicationUri ?? '').isNotEmpty &&
            a.clientApplicationUri == b.clientApplicationUri,
      _ => false,
    };
  }
}

/// open62541's default access control (`UA_AccessControl_default`) in
/// Dart: anonymous sessions if [allowAnonymous], user name logins against
/// [users] (name to password, compared in constant time), and certificate
/// logins for every certificate the server's trust list accepts if
/// [allowCertificate]. Everything else is allowed. A `Server` without an
/// `accessControl` uses one built from its `allowAnonymous`, `users` and
/// `trustList`.
///
/// The session context is the user name for a user name login, the
/// certificate for a certificate login and `null` for an anonymous one.
class DefaultAccessControl extends AccessControl {
  DefaultAccessControl({
    this.allowAnonymous = true,
    Map<String, String> users = const {},
    this.allowCertificate = false,
  }) : users = Map.unmodifiable(users);

  final bool allowAnonymous;
  final Map<String, String> users;
  final bool allowCertificate;

  @override
  Set<UserTokenType> get userTokenTypes => {
    if (allowAnonymous) UserTokenType.UA_USERTOKENTYPE_ANONYMOUS,
    if (users.isNotEmpty) UserTokenType.UA_USERTOKENTYPE_USERNAME,
    if (allowCertificate) UserTokenType.UA_USERTOKENTYPE_CERTIFICATE,
  };

  @override
  Object? activateSession(SessionActivation activation) {
    switch (activation.tokenType) {
      case UserTokenType.UA_USERTOKENTYPE_ANONYMOUS:
        if (!allowAnonymous) throw const UaStatusException(raw.UA_STATUSCODE_BADIDENTITYTOKENINVALID);
        return null;
      case UserTokenType.UA_USERTOKENTYPE_USERNAME:
        final username = activation.username ?? '';
        final password = activation.password ?? Uint8List(0);
        if (username.isEmpty && password.isEmpty) {
          throw const UaStatusException(raw.UA_STATUSCODE_BADIDENTITYTOKENINVALID);
        }
        final expected = users[username];
        final match = _constantTimeEquals(utf8.encode(expected ?? ''), password) & (expected != null);
        if (!match) throw const UaStatusException(raw.UA_STATUSCODE_BADUSERACCESSDENIED);
        return username;
      case UserTokenType.UA_USERTOKENTYPE_CERTIFICATE:
        if (!allowCertificate) throw const UaStatusException(raw.UA_STATUSCODE_BADIDENTITYTOKENINVALID);
        return activation.userCertificate;
      default:
        throw const UaStatusException(raw.UA_STATUSCODE_BADIDENTITYTOKENINVALID);
    }
  }

  /// Every attempt, for a known user or an unknown one (against an empty
  /// password), compares the same number of bytes, at least 256, so the
  /// timing shows neither whether the user exists nor how long either
  /// password is.
  static bool _constantTimeEquals(List<int> a, List<int> b) {
    var diff = a.length ^ b.length;
    final n = max(256, max(a.length, b.length));
    for (var i = 0; i < n; i++) {
      diff |= (i < a.length ? a[i] : 0) ^ (i < b.length ? b[i] : 0);
    }
    return diff == 0;
  }
}

/// `UA_UserNameIdentityToken`, absent from the bindings.
final class _UserNameIdentityToken extends ffi.Struct {
  external raw.UA_String policyId;
  external raw.UA_String userName;
  external raw.UA_ByteString password;
  external raw.UA_String encryptionAlgorithm;
}

/// `UA_X509IdentityToken`, absent from the bindings.
final class _X509IdentityToken extends ffi.Struct {
  external raw.UA_String policyId;
  external raw.UA_ByteString certificateData;
}

final class _NodeRef implements NodeRef {
  _NodeRef(this._contextOut);

  final ffi.Pointer<ffi.Pointer<ffi.Void>> _contextOut;
  ffi.Pointer<raw.UA_Server> _server = ffi.nullptr;
  ffi.Pointer<raw.UA_NodeId> _id = ffi.nullptr;
  int? _tag;
  NodeId? _nodeId;

  /// Points this reference at [id]; [context] is the node context when the
  /// hook has it, else it is looked up on first use.
  _NodeRef at(ffi.Pointer<raw.UA_Server> server, ffi.Pointer<raw.UA_NodeId> id, int? context) {
    _server = server;
    _id = id;
    _tag = context == null ? null : _accessTagOf(context);
    _nodeId = null;
    return this;
  }

  @override
  int get tag => _tag ??= raw.UA_Server_getNodeContext(_server, _id.ref, _contextOut) == raw.UA_STATUSCODE_GOOD
      ? _accessTagOf(_contextOut.value.address)
      : 0;

  @override
  NodeId get nodeId => _nodeId ??= NodeIdFfi.fromRaw(_id.ref);
}

typedef _NodeHook<R extends ffi.NativeType> =
    R Function(
      ffi.Pointer<raw.UA_Server>,
      ffi.Pointer<raw.UA_AccessControl>,
      ffi.Pointer<raw.UA_NodeId>,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<raw.UA_NodeId>,
      ffi.Pointer<ffi.Void>,
    );
typedef _ItemHook =
    ffi.Bool Function(
      ffi.Pointer<raw.UA_Server>,
      ffi.Pointer<raw.UA_AccessControl>,
      ffi.Pointer<raw.UA_NodeId>,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
    );
typedef _Notification = ffi.Void Function(ffi.Pointer<raw.UA_Server>, ffi.UnsignedInt, raw.UA_KeyValueMap);

final _log = Logger('open62541.Server');

/// The `applicationUri` and the `applicationName` text of the
/// ApplicationDescription session [sessionId] was created with (the
/// `0:clientDescription` session attribute), copied to Dart; `null` for an
/// unknown session.
({String applicationUri, String applicationName})? clientDescriptionOf(
  ffi.Pointer<raw.UA_Server> server,
  ffi.Pointer<raw.UA_NodeId> sessionId,
) => using((arena) {
  final variant = arena<raw.UA_Variant>();
  final key = raw.UA_QUALIFIEDNAME(0, 'clientDescription'.toNativeUtf8(allocator: arena).cast());
  // A shallow view into the session's own description.
  if (raw.UA_Server_getSessionAttribute(server, sessionId, key, variant) != raw.UA_STATUSCODE_GOOD ||
      variant.ref.type != getTypeByIndex(raw.UA_TYPES_APPLICATIONDESCRIPTION) ||
      variant.ref.data == ffi.nullptr) {
    return null;
  }
  final description = variant.ref.data.cast<raw.UA_ApplicationDescription>().ref;
  String text(raw.UA_String s) => s.length == 0 ? '' : s.value;
  return (applicationUri: text(description.applicationUri), applicationName: text(description.applicationName.text));
}, ua_calloc);

/// open62541's ids for the token policies of its default plugin
/// (`plugins/ua_accesscontrol_default.c`); the server appends the mode and
/// policy of each endpoint.
const _policyIds = {
  UserTokenType.UA_USERTOKENTYPE_ANONYMOUS: 'open62541-anonymous-policy',
  UserTokenType.UA_USERTOKENTYPE_USERNAME: 'open62541-username-policy',
  UserTokenType.UA_USERTOKENTYPE_CERTIFICATE: 'open62541-certificate-policy',
};

/// Drives open62541's `UA_AccessControl` hooks from an [AccessControl].
///
/// A session's context in open62541 is an int handle into [_sessions], and a
/// node's context is its access tag, so a hook is a map lookup. Every
/// callable stays open until [close], which the server calls after
/// `UA_Server_delete` has returned: closeSession runs inside it.
final class AccessControlHooks {
  AccessControlHooks(this.accessControl);

  final AccessControl accessControl;
  final Map<int, ActiveSession> _sessions = {};

  // Remote addresses by the address of the SecureChannel's remoteCertificate
  // field, which open62541 passes both to the channel notification and to
  // activateSession: the channel's identity on both sides.
  final Map<int, String> _remoteAddresses = {};
  int _nextHandle = 1;
  final Set<String> _hooksThatThrew = {};
  bool _nodeHooks = false;

  final ffi.Pointer<ffi.Pointer<ffi.Void>> _contextOut = ua_calloc<ffi.Pointer<ffi.Void>>();
  late final _NodeRef _node = _NodeRef(_contextOut);
  late final _NodeRef _object = _NodeRef(_contextOut);
  final List<ffi.NativeCallable> _callables = [];

  /// The token types [accessControl] offers, in wire order, checked against
  /// what the server can verify: a certificate token needs [certificateTrust]
  /// (a server trust list).
  static List<UserTokenType> tokenTypes(AccessControl accessControl, {required bool certificateTrust}) {
    final offered = accessControl.userTokenTypes;
    final types = UserTokenType.values.where(offered.contains).toList();
    if (types.isEmpty) {
      throw ArgumentError.value(
        offered,
        'accessControl.userTokenTypes',
        'offers no token type: no client could log in',
      );
    }
    if (types.any((type) => !_policyIds.containsKey(type))) {
      throw ArgumentError.value(offered, 'accessControl.userTokenTypes', 'issued tokens are not supported');
    }
    if (types.contains(UserTokenType.UA_USERTOKENTYPE_CERTIFICATE) && !certificateTrust) {
      throw ArgumentError.value(
        offered,
        'accessControl.userTokenTypes',
        'a certificate login needs a certificate and a non-empty trustList to verify the user certificates',
      );
    }
    return types;
  }

  /// The session behind a native session context, if activated here.
  ActiveSession? session(ffi.Pointer<ffi.Void> sessionContext) => _sessions[sessionContext.address];

  /// Installs the hooks into [config]'s access control, which
  /// `UA_AccessControl_default` set up: its clear and context stay C-owned,
  /// and the token policies it built are replaced by one per type in
  /// [types] (the server copies them onto every endpoint). [nodeHooks] false
  /// leaves the plugin's per-node functions, which allow everything, in
  /// place.
  void install(ffi.Pointer<raw.UA_ServerConfig> config, List<UserTokenType> types, {bool nodeHooks = true}) {
    final ac = config.ref.accessControl;
    final policyType = getTypeByIndex(raw.UA_TYPES_USERTOKENPOLICY);
    final policies = raw.UA_Array_new(types.length, policyType).cast<raw.UA_UserTokenPolicy>();
    if (policies == ffi.nullptr) throw const UaStatusException(raw.UA_STATUSCODE_BADOUTOFMEMORY);
    for (var i = 0; i < types.length; i++) {
      policies[i].tokenTypeAsInt = types[i].value;
      policies[i].policyId.set(_policyIds[types[i]]!);
    }
    raw.UA_Array_delete(ac.userTokenPolicies.cast(), ac.userTokenPoliciesSize, policyType);
    ac.userTokenPolicies = policies;
    ac.userTokenPoliciesSize = types.length;

    ffi.Pointer<ffi.NativeFunction<T>> keep<T extends Function>(ffi.NativeCallable<T> callable) {
      _callables.add(callable);
      return callable.nativeFunction;
    }

    ac.activateSession = keep(
      ffi.NativeCallable<
        raw.UA_StatusCode Function(
          ffi.Pointer<raw.UA_Server>,
          ffi.Pointer<raw.UA_AccessControl>,
          ffi.Pointer<raw.UA_EndpointDescription>,
          ffi.Pointer<raw.UA_ByteString>,
          ffi.Pointer<raw.UA_NodeId>,
          ffi.Pointer<raw.UA_ExtensionObject>,
          ffi.Pointer<ffi.Pointer<ffi.Void>>,
        )
      >.isolateLocal(_activateSession, exceptionalReturn: raw.UA_STATUSCODE_BADUSERACCESSDENIED),
    );
    ac.closeSession = keep(
      ffi.NativeCallable<
        ffi.Void Function(
          ffi.Pointer<raw.UA_Server>,
          ffi.Pointer<raw.UA_AccessControl>,
          ffi.Pointer<raw.UA_NodeId>,
          ffi.Pointer<ffi.Void>,
        )
      >.isolateLocal(_closeSession),
    );
    // The plugin's own reads a session attribute only its activateSession
    // sets.
    ac.allowTransferSubscription = keep(
      ffi.NativeCallable<_NodeHook<ffi.Bool>>.isolateLocal(_allowTransferSubscription, exceptionalReturn: false),
    );
    config.ref.secureChannelNotificationCallback = keep(
      ffi.NativeCallable<_Notification>.isolateLocal(_channelNotification),
    );
    _nodeHooks = nodeHooks;
    if (!nodeHooks) return;

    ac.getUserRightsMask = keep(
      ffi.NativeCallable<_NodeHook<ffi.Uint32>>.isolateLocal(_userRightsMask, exceptionalReturn: 0),
    );
    ac.getUserAccessLevel = keep(
      ffi.NativeCallable<_NodeHook<ffi.Uint8>>.isolateLocal(_userAccessLevel, exceptionalReturn: 0),
    );
    ac.getUserExecutable = keep(
      ffi.NativeCallable<_NodeHook<ffi.Bool>>.isolateLocal(_userExecutable, exceptionalReturn: false),
    );
    ac.getUserExecutableOnObject = keep(
      ffi.NativeCallable<
        ffi.Bool Function(
          ffi.Pointer<raw.UA_Server>,
          ffi.Pointer<raw.UA_AccessControl>,
          ffi.Pointer<raw.UA_NodeId>,
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<raw.UA_NodeId>,
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<raw.UA_NodeId>,
          ffi.Pointer<ffi.Void>,
        )
      >.isolateLocal(_userExecutableOnObject, exceptionalReturn: false),
    );
    ac.allowBrowseNode = keep(
      ffi.NativeCallable<_NodeHook<ffi.Bool>>.isolateLocal(_allowBrowse, exceptionalReturn: false),
    );
    // Each item struct starts with the NodeId the hook decides about:
    // AddNodesItem.parentNodeId (an ExpandedNodeId, whose first member is
    // the NodeId), DeleteNodesItem.nodeId and the sourceNodeId of the
    // reference items.
    ffi.Pointer<ffi.NativeFunction<_ItemHook>> itemHook(String name, bool Function(Object?, NodeRef) decide) {
      bool hook(
        ffi.Pointer<raw.UA_Server> server,
        ffi.Pointer<raw.UA_AccessControl> ac,
        ffi.Pointer<raw.UA_NodeId> sessionId,
        ffi.Pointer<ffi.Void> sessionContext,
        ffi.Pointer<ffi.Void> item,
      ) => _decide(name, sessionContext, false, (context) => decide(context, _node.at(server, item.cast(), null)));
      return keep(ffi.NativeCallable<_ItemHook>.isolateLocal(hook, exceptionalReturn: false));
    }

    ac.allowAddNode = itemHook('allowAddNode', accessControl.allowAddNode).cast();
    ac.allowAddReference = itemHook('allowAddReference', accessControl.allowAddReference).cast();
    ac.allowDeleteNode = itemHook('allowDeleteNode', accessControl.allowDeleteNode).cast();
    ac.allowDeleteReference = itemHook('allowDeleteReference', accessControl.allowDeleteReference).cast();
  }

  /// The session's user access level for [nodeId] as the getUserAccessLevel
  /// hook answers it, for a service on which open62541 does not ask
  /// (HistoryRead): `0xFF` without node hooks, `0` without an activated
  /// session or when the hook throws.
  int userAccessLevel(
    ffi.Pointer<raw.UA_Server> server,
    ffi.Pointer<ffi.Void> sessionContext,
    ffi.Pointer<raw.UA_NodeId> nodeId,
  ) {
    if (!_nodeHooks) return 0xFF;
    return _decide(
      'userAccessLevel',
      sessionContext,
      0,
      (context) => accessControl.userAccessLevel(context, _node.at(server, nodeId, null)) & 0xFF,
    );
  }

  /// [decide] with the context of the session behind [sessionContext]; [deny]
  /// without one, or when [decide] throws (logged once per [hook]).
  T _decide<T>(String hook, ffi.Pointer<ffi.Void> sessionContext, T deny, T Function(Object? context) decide) {
    final session = _sessions[sessionContext.address];
    if (session == null) return deny;
    try {
      return decide(session.context);
    } catch (error, stack) {
      _threw(hook, error, stack);
      return deny;
    }
  }

  void _threw(String hook, Object error, StackTrace stack) {
    if (_hooksThatThrew.add(hook)) {
      _log.severe('AccessControl.$hook threw, the request is denied (logged once)', error, stack);
    }
  }

  int _userRightsMask(
    ffi.Pointer<raw.UA_Server> server,
    ffi.Pointer<raw.UA_AccessControl> ac,
    ffi.Pointer<raw.UA_NodeId> sessionId,
    ffi.Pointer<ffi.Void> sessionContext,
    ffi.Pointer<raw.UA_NodeId> nodeId,
    ffi.Pointer<ffi.Void> nodeContext,
  ) => _decide(
    'userRightsMask',
    sessionContext,
    0,
    (context) => accessControl.userRightsMask(context, _node.at(server, nodeId, nodeContext.address)) & 0xFFFFFFFF,
  );

  int _userAccessLevel(
    ffi.Pointer<raw.UA_Server> server,
    ffi.Pointer<raw.UA_AccessControl> ac,
    ffi.Pointer<raw.UA_NodeId> sessionId,
    ffi.Pointer<ffi.Void> sessionContext,
    ffi.Pointer<raw.UA_NodeId> nodeId,
    ffi.Pointer<ffi.Void> nodeContext,
  ) => _decide(
    'userAccessLevel',
    sessionContext,
    0,
    (context) => accessControl.userAccessLevel(context, _node.at(server, nodeId, nodeContext.address)) & 0xFF,
  );

  bool _userExecutable(
    ffi.Pointer<raw.UA_Server> server,
    ffi.Pointer<raw.UA_AccessControl> ac,
    ffi.Pointer<raw.UA_NodeId> sessionId,
    ffi.Pointer<ffi.Void> sessionContext,
    ffi.Pointer<raw.UA_NodeId> methodId,
    ffi.Pointer<ffi.Void> methodContext,
  ) => _decide(
    'userExecutable',
    sessionContext,
    false,
    (context) => accessControl.userExecutable(context, _node.at(server, methodId, methodContext.address)),
  );

  bool _userExecutableOnObject(
    ffi.Pointer<raw.UA_Server> server,
    ffi.Pointer<raw.UA_AccessControl> ac,
    ffi.Pointer<raw.UA_NodeId> sessionId,
    ffi.Pointer<ffi.Void> sessionContext,
    ffi.Pointer<raw.UA_NodeId> methodId,
    ffi.Pointer<ffi.Void> methodContext,
    ffi.Pointer<raw.UA_NodeId> objectId,
    ffi.Pointer<ffi.Void> objectContext,
  ) => _decide(
    'userExecutableOnObject',
    sessionContext,
    false,
    (context) => accessControl.userExecutableOnObject(
      context,
      _node.at(server, methodId, methodContext.address),
      _object.at(server, objectId, objectContext.address),
    ),
  );

  bool _allowBrowse(
    ffi.Pointer<raw.UA_Server> server,
    ffi.Pointer<raw.UA_AccessControl> ac,
    ffi.Pointer<raw.UA_NodeId> sessionId,
    ffi.Pointer<ffi.Void> sessionContext,
    ffi.Pointer<raw.UA_NodeId> nodeId,
    ffi.Pointer<ffi.Void> nodeContext,
  ) => _decide(
    'allowBrowse',
    sessionContext,
    false,
    (context) => accessControl.allowBrowse(context, _node.at(server, nodeId, nodeContext.address)),
  );

  bool _allowTransferSubscription(
    ffi.Pointer<raw.UA_Server> server,
    ffi.Pointer<raw.UA_AccessControl> ac,
    ffi.Pointer<raw.UA_NodeId> oldSessionId,
    ffi.Pointer<ffi.Void> oldContext,
    ffi.Pointer<raw.UA_NodeId> newSessionId,
    ffi.Pointer<ffi.Void> newContext,
  ) {
    final to = _sessions[newContext.address];
    if (to == null) return false;
    try {
      return accessControl.allowTransferSubscription(
        oldSessionId == ffi.nullptr ? null : _sessions[oldContext.address],
        to,
      );
    } catch (error, stack) {
      _threw('allowTransferSubscription', error, stack);
      return false;
    }
  }

  int _activateSession(
    ffi.Pointer<raw.UA_Server> server,
    ffi.Pointer<raw.UA_AccessControl> ac,
    ffi.Pointer<raw.UA_EndpointDescription> endpoint,
    ffi.Pointer<raw.UA_ByteString> channelCertificate,
    ffi.Pointer<raw.UA_NodeId> sessionIdPtr,
    ffi.Pointer<raw.UA_ExtensionObject> token,
    ffi.Pointer<ffi.Pointer<ffi.Void>> sessionContext,
  ) {
    Uint8List? password;
    try {
      final previousHandle = sessionContext.value.address;
      final previous = _sessions[previousHandle];
      final encoding = token.ref.encodingAsInt;
      final decoded =
          encoding == raw.UA_ExtensionObjectEncoding.UA_EXTENSIONOBJECT_DECODED.value ||
              encoding == raw.UA_ExtensionObjectEncoding.UA_EXTENSIONOBJECT_DECODED_NODELETE.value
          ? token.ref.content.decoded
          : null;
      var tokenType = UserTokenType.UA_USERTOKENTYPE_ANONYMOUS;
      String? username;
      Certificate? userCertificate;
      if (decoded != null && decoded.type == getTypeByIndex(raw.UA_TYPES_USERNAMEIDENTITYTOKEN)) {
        final userName = decoded.data.cast<_UserNameIdentityToken>().ref;
        tokenType = UserTokenType.UA_USERTOKENTYPE_USERNAME;
        username = userName.userName.length == 0 ? '' : userName.userName.value;
        password = Uint8List.fromList(userName.password.length == 0 ? const [] : userName.password.asTypedList());
      } else if (decoded != null && decoded.type == getTypeByIndex(raw.UA_TYPES_X509IDENTITYTOKEN)) {
        final x509 = decoded.data.cast<_X509IdentityToken>().ref;
        tokenType = UserTokenType.UA_USERTOKENTYPE_CERTIFICATE;
        userCertificate = leafCertificate(Uint8List.fromList(x509.certificateData.asTypedList()));
      } else if (decoded != null && decoded.type != getTypeByIndex(raw.UA_TYPES_ANONYMOUSIDENTITYTOKEN)) {
        return raw.UA_STATUSCODE_BADIDENTITYTOKENINVALID;
      }
      final sessionId = NodeIdFfi.fromRaw(sessionIdPtr.ref);
      final activation = SessionActivation(
        sessionId: sessionId,
        tokenType: tokenType,
        username: username,
        password: password,
        userCertificate: userCertificate,
        clientCertificate: channelCertificate.ref.length == 0
            ? null
            : leafCertificate(Uint8List.fromList(channelCertificate.ref.asTypedList())),
        clientApplicationUri: clientDescriptionOf(server, sessionIdPtr)?.applicationUri,
        securityMode: MessageSecurityMode.fromValue(endpoint.ref.securityModeAsInt),
        securityPolicyUri: endpoint.ref.securityPolicyUri.length == 0 ? '' : endpoint.ref.securityPolicyUri.value,
        reactivation: previous != null,
        previousContext: previous?.context,
        remoteAddress: _remoteAddresses[channelCertificate.address],
      );
      final context = accessControl.activateSession(activation);
      final handle = previous != null ? previousHandle : _nextHandle++;
      _sessions[handle] = ActiveSession(sessionId, context, activation);
      sessionContext.value = ffi.Pointer.fromAddress(handle);
      return raw.UA_STATUSCODE_GOOD;
    } on UaStatusException catch (e) {
      return e.statusCode & 0x80000000 != 0 ? e.statusCode : raw.UA_STATUSCODE_BADUSERACCESSDENIED;
    } catch (error, stack) {
      _threw('activateSession', error, stack);
      return raw.UA_STATUSCODE_BADUSERACCESSDENIED;
    } finally {
      password?.fillRange(0, password.length, 0);
    }
  }

  void _closeSession(
    ffi.Pointer<raw.UA_Server> server,
    ffi.Pointer<raw.UA_AccessControl> ac,
    ffi.Pointer<raw.UA_NodeId> sessionId,
    ffi.Pointer<ffi.Void> sessionContext,
  ) {
    final session = _sessions.remove(sessionContext.address);
    if (session == null) return;
    try {
      accessControl.closeSession(session);
    } catch (error, stack) {
      _threw('closeSession', error, stack);
    }
  }

  void _channelNotification(ffi.Pointer<raw.UA_Server> server, int type, raw.UA_KeyValueMap payload) {
    final opened = type == raw.UA_ApplicationNotificationType.UA_APPLICATIONNOTIFICATIONTYPE_SECURECHANNEL_OPENED.value;
    final closed = type == raw.UA_ApplicationNotificationType.UA_APPLICATIONNOTIFICATIONTYPE_SECURECHANNEL_CLOSED.value;
    if (!opened && !closed) return;
    String? address;
    var channel = 0;
    for (var i = 0; i < payload.mapSize; i++) {
      final pair = payload.map[i];
      final name = pair.key.name.value;
      if (name == 'remote-certificate') {
        channel = pair.value.data.address;
      } else if (name == 'remote-address' && pair.value.type == getTypeByIndex(raw.UA_TYPES_STRING)) {
        final value = pair.value.data.cast<raw.UA_String>().ref;
        address = value.length == 0 ? null : value.value;
      }
    }
    if (channel == 0) return;
    if (opened && address != null) {
      _remoteAddresses[channel] = address;
    } else if (closed) {
      _remoteAddresses.remove(channel);
    }
  }

  /// Closes every native callable. Call only after `UA_Server_delete`.
  void close() {
    for (final callable in _callables) {
      callable.close();
    }
    _callables.clear();
    _sessions.clear();
    _remoteAddresses.clear();
    ua_calloc.free(_contextOut);
  }
}
