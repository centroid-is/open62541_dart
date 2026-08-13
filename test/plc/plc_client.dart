// Session-conserving client for session-constrained controllers (M240/M262).
//
// The problem: these controllers have a tiny session table (~4-5). A normal
// client holds its session open for its whole lifetime; if it also crashes or
// drops without a clean CloseSession, the stale session squats a slot until the
// controller's (long) timeout expires. A handful of dev restarts exhausts it.
//
// The solution here is a LEASED session: the client holds NO session while
// idle. It connects on demand for a read/write, then releases the session after
// a short idle window (default 2s) -- cleanly closing it on the controller. An
// occasional-poll HMI therefore never squats a slot, and even an abrupt death
// only leaves a session for the short requestedSessionTimeout the underlying
// [PlcSession] requests.
//
// For a client that genuinely needs a persistent session (e.g. subscriptions),
// use [PlcSession] directly with its short session timeout instead.

import 'dart:async';

import 'package:open62541/open62541.dart';
import 'plc_config.dart';
import 'plc_session.dart';

class LeasedPlcClient {
  LeasedPlcClient(this.config, {this.idle = const Duration(seconds: 2)});

  final PlcConfig config;

  /// How long to keep the session after the last operation before releasing it.
  /// Duration.zero closes immediately after each operation.
  final Duration idle;

  PlcSession? _session;
  Timer? _idleTimer;
  Future<void>? _connecting;
  bool _disposed = false;
  int _leases = 0;

  bool get hasOpenSession => _session != null;

  /// Runs [action] with a live session, opening one on demand and scheduling
  /// its release once the idle window elapses with no further activity.
  Future<T> use<T>(Future<T> Function(PlcSession s) action) async {
    if (_disposed) throw StateError('LeasedPlcClient disposed');
    final session = await _acquire();
    _leases++;
    try {
      return await action(session);
    } finally {
      _leases--;
      _scheduleRelease();
    }
  }

  /// Convenience wrappers over the leased session.
  Future<DynamicValue> read(String browseName) => use((s) async => s.client.read(await s.node(browseName)));

  Future<void> write(String browseName, DynamicValue value) =>
      use((s) async => s.client.write(await s.node(browseName), value));

  Future<PlcSession> _acquire() async {
    _idleTimer?.cancel();
    if (_session != null) return _session!;
    // Coalesce concurrent opens.
    _connecting ??= _open();
    try {
      await _connecting;
    } finally {
      _connecting = null;
    }
    return _session!;
  }

  Future<void> _open() async {
    final s = await PlcSession.open(config);
    _session = s;
  }

  void _scheduleRelease() {
    _idleTimer?.cancel();
    if (_leases > 0) return; // still in use
    if (idle == Duration.zero) {
      unawaited(_release());
      return;
    }
    _idleTimer = Timer(idle, () => unawaited(_release()));
  }

  Future<void> _release() async {
    if (_leases > 0) return; // became busy again
    final s = _session;
    _session = null;
    _idleTimer?.cancel();
    if (s != null) await s.dispose(); // clean CloseSession -> frees the slot
  }

  Future<void> dispose() async {
    _disposed = true;
    _idleTimer?.cancel();
    await _release();
  }
}
