// Per-PLC connection config, read from the environment so the same tests run
// against real hardware or a local emulator.
//
// For each target set (at minimum) its URL; username/password default to the
// fixture creds. Set the URL to the literal `emulator` to spin up the matching
// asyncua emulator locally (used for `verify locally`).
//
//   PLC_TWINCAT_URL   e.g. opc.tcp://192.168.0.10:4840   (or `emulator`)
//   PLC_TWINCAT_USER  / PLC_TWINCAT_PASS
//   PLC_TWINCAT_MAX_SESSIONS   (optional; default below)
//   ...same for PLC_M240_* and PLC_M262_*

import 'dart:io';

enum PlcTarget { twincat, m240, m262 }

class PlcConfig {
  PlcConfig({
    required this.target,
    required this.url,
    required this.username,
    required this.password,
    required this.maxSessions,
    required this.supportsComplexTypes,
    required this.useEmulator,
    required this.sessionTimeout,
    required this.secureChannelLifetime,
  });

  final PlcTarget target;
  final String url;
  final String username;
  final String password;

  /// Requested session timeout. Deliberately SHORT for these controllers: if our
  /// client dies or the link drops without a clean CloseSession, the PLC reaps
  /// the abandoned session after roughly this long, freeing the slot -- instead
  /// of the multi-minute vendor default that piles stale sessions up until the
  /// (tiny) session table is exhausted. The client keepalives keep a live
  /// session from expiring.
  final Duration sessionTimeout;

  /// Secure-channel lifetime (also kept short so a dropped channel is reaped).
  final Duration secureChannelLifetime;

  /// Hard budget: the suite must NEVER hold more than this many concurrent
  /// sessions against this controller (small PLCs exhaust quickly).
  final int maxSessions;

  /// TwinCAT & M262 expose structured types; the M240 does not.
  final bool supportsComplexTypes;

  /// True when [url] was `emulator` — the session manager starts a local
  /// asyncua emulator and connects to it instead.
  final bool useEmulator;

  String get name => target.name;

  /// The emulator profile name (also the PLC program folder name).
  String get profile => switch (target) {
    PlcTarget.twincat => 'twincat',
    PlcTarget.m240 => 'm240',
    PlcTarget.m262 => 'm262',
  };

  /// Reads config for [target] from the environment. Returns null when the
  /// target is not configured (its URL is unset) so tests can skip it.
  static PlcConfig? fromEnv(PlcTarget target) {
    final prefix = 'PLC_${target.name.toUpperCase()}';
    final url = Platform.environment['${prefix}_URL'];
    if (url == null || url.trim().isEmpty) return null;

    final defaults = _defaults[target]!;
    final timeoutMs = int.tryParse(Platform.environment['${prefix}_SESSION_TIMEOUT_MS'] ?? '') ?? defaults.timeoutMs;
    return PlcConfig(
      target: target,
      url: url.trim(),
      username: Platform.environment['${prefix}_USER'] ?? _fixtureUser,
      password: Platform.environment['${prefix}_PASS'] ?? _fixturePass,
      maxSessions: int.tryParse(Platform.environment['${prefix}_MAX_SESSIONS'] ?? '') ?? defaults.maxSessions,
      supportsComplexTypes: defaults.complex,
      useEmulator: url.trim().toLowerCase() == 'emulator',
      sessionTimeout: Duration(milliseconds: timeoutMs),
      secureChannelLifetime: Duration(milliseconds: (timeoutMs * 0.75).round()),
    );
  }

  static List<PlcConfig> configured() => PlcTarget.values.map(fromEnv).whereType<PlcConfig>().toList(growable: false);

  // Conservative session budgets + SHORT session timeouts (overridable via env).
  // M240/M241 hard-cap is 4 parallel sessions; the others are small too. A short
  // timeout means an abandoned session is reaped in ~seconds instead of minutes.
  static const _defaults = {
    PlcTarget.twincat: (maxSessions: 8, complex: true, timeoutMs: 20000),
    PlcTarget.m240: (maxSessions: 4, complex: false, timeoutMs: 20000),
    PlcTarget.m262: (maxSessions: 5, complex: true, timeoutMs: 20000),
  };
}

/// Default credentials the emulators and PLC programs are set up with. Override
/// per target with `PLC_<X>_USER` / `PLC_<X>_PASS` for real hardware.
const _fixtureUser = 'tester';
const _fixturePass = 'test-pass-1';
const fixtureUser = _fixtureUser;
const fixturePass = _fixturePass;
