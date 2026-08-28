import 'package:flutter/foundation.dart';

/// OD-05 — crash/diagnostics reporting must not egress while cloud consent is
/// off.
///
/// ## Why this is a gate and not an init-time check
/// Sentry is initialised in `main()` **before** the encrypted database is open,
/// and consent lives in that database. So consent cannot be known at init time.
/// Refusing to initialise would also lose early-startup crashes for consenting
/// users — including crashes in bootstrap itself, which is where the most
/// valuable ones live.
///
/// The SDK is therefore initialised and armed, but every outbound event and
/// breadcrumb passes this gate first. Nothing leaves the device until consent is
/// positively established.
///
/// ## Fail closed
/// The default is DENY. It stays denied for the whole window between process
/// start and the first successful settings read, and it returns to denied on
/// sign-out or revocation. A crash during that window is dropped — which is the
/// correct trade: an unsent crash report costs a diagnostic, an unconsented one
/// costs a privacy promise.
///
/// This deliberately does not read the database itself. `beforeSend` is
/// synchronous and may run on a crash path where async work is unsafe, so the
/// value is *pushed* here by the consent-aware layer rather than pulled.
class DiagnosticsConsentGate {
  DiagnosticsConsentGate._();

  static final ValueNotifier<bool> _allowed = ValueNotifier<bool>(false);

  /// Whether a diagnostics payload may leave the device right now.
  static bool get allowed => _allowed.value;

  /// Listenable for anything that wants to react to the gate opening/closing.
  static ValueListenable<bool> get listenable => _allowed;

  /// Pushed by the consent-aware layer after settings load, and again on every
  /// consent change / sign-out.
  static void set(bool value) => _allowed.value = value;

  /// Explicit re-close. Used on sign-out and on revocation so a later crash
  /// cannot ride out on a stale grant.
  static void revoke() => _allowed.value = false;

  /// Visible for testing only.
  @visibleForTesting
  static void resetForTest() => _allowed.value = false;
}
