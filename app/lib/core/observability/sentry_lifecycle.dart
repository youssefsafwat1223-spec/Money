import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../backend/sentry_config.dart';
import '../privacy/cloud_egress_gate.dart';
import '../privacy/diagnostics_consent_gate.dart';
import 'telemetry_sanitizer.dart';

/// Astra H2.5: Sentry is a native SDK reachable from Dart, so it is NOT
/// initialised in `main()` any more. It runs only while BOTH hold:
///  * the egress gate permits (resolved, durable ON record, no freeze), and
///  * the diagnostics consent gate is open (`DiagnosticsConsentGate`).
///
/// A transition to "not permitted" calls `Sentry.close()` (which also stops the
/// native SDK and its cached-envelope/session sending); permitted again
/// re-initialises. Verified from sentry_flutter 9.22.0: before
/// `SentryFlutter.init` nothing is created (no hub, no native init, no
/// transport), so nothing — sessions or cached envelopes — can be sent earlier.
/// `main()` therefore only [attach]es the listeners and calls `runApp`.
class SentryLifecycle {
  SentryLifecycle._();

  static Future<void> Function(FlutterOptionsConfiguration) _init =
      (configure) => SentryFlutter.init(configure);
  static Future<void> Function() _close = Sentry.close;
  static bool Function() _configured = () => SentryConfig.isConfigured;
  static bool _running = false;
  static bool _attached = false;
  static Future<void> _chain = Future<void>.value();
  static CloudEgressGate? _attachedGate;

  /// Whether the SDK is currently initialised by this class.
  static bool get isRunning => _running;

  /// Wires the listeners (idempotent). Starts nothing by itself.
  static void attach() {
    final gate = CloudEgressGate.instance;
    if (_attached && identical(_attachedGate, gate)) return;
    if (_attached) {
      _attachedGate?.permitNotifier.removeListener(requestReconcile);
    } else {
      DiagnosticsConsentGate.listenable.addListener(requestReconcile);
    }
    gate.permitNotifier.addListener(requestReconcile);
    _attached = true;
    _attachedGate = gate;
  }

  /// Serialised: concurrent triggers never overlap an init with a close.
  static Future<void> requestReconcile() =>
      _chain = _chain.then((_) => _reconcile()).catchError((Object _) {});

  static Future<void> _reconcile() async {
    final want = _configured() &&
        DiagnosticsConsentGate.allowed &&
        await CloudEgressGate.instance.permits();
    if (want && !_running) {
      _running = true;
      try {
        await _init(configure);
      } catch (_) {
        _running = false;
      }
    } else if (!want && _running) {
      _running = false;
      try {
        await _close();
      } catch (_) {}
    }
  }

  /// Same options `main()` used to pass, plus the egress check in the hooks.
  @visibleForTesting
  static void configure(SentryFlutterOptions options) {
    options.dsn = SentryConfig.dsn;
    options.sendDefaultPii = false;
    options.tracesSampleRate = 0.0;
    options.attachScreenshot = false;
    // MALI-032 — native crashes are serialized by the native SDK and do
    // NOT pass through the Dart boundary below, so silence native
    // auto-breadcrumbs (UI/navigation/system) which could otherwise ride
    // along on a native crash payload unscrubbed.
    options.enableAutoNativeBreadcrumbs = false;
    // MALI-032 — allowlist telemetry boundary. Every outbound event and
    // breadcrumb is stripped down to allowlisted, redacted fields so no
    // free-form text (SMS/merchant/amount/account/token) can leak. Covers
    // beforeSend AND beforeBreadcrumb — never assume the former covers the
    // latter. See TelemetrySanitizer for the exact contract and the
    // documented native limitation.
    // OD-05 (C-3) — consent gate BEFORE sanitisation. Sanitising decides
    // what a payload may contain; it never decides whether the payload may
    // exist. Astra H2.5 adds the egress mirror: a payload racing a transition
    // to OFF is dropped here as well as by `Sentry.close()`.
    options.beforeSend = (event, hint) => DiagnosticsConsentGate.allowed &&
            CloudEgressGate.instance.permitsNetworkSync
        ? TelemetrySanitizer.sanitizeEvent(event)
        : null;
    options.beforeBreadcrumb = (crumb, hint) =>
        DiagnosticsConsentGate.allowed &&
                CloudEgressGate.instance.permitsNetworkSync
            ? TelemetrySanitizer.sanitizeBreadcrumb(crumb)
            : null;
  }

  @visibleForTesting
  static void debugSetHooks({
    Future<void> Function(FlutterOptionsConfiguration)? init,
    Future<void> Function()? close,
    bool Function()? configured,
  }) {
    if (configured != null) _configured = configured;
    if (init != null) _init = init;
    if (close != null) _close = close;
  }

  @visibleForTesting
  static void debugReset() {
    _running = false;
    _chain = Future<void>.value();
    if (_attached) {
      DiagnosticsConsentGate.listenable.removeListener(requestReconcile);
      _attachedGate?.permitNotifier.removeListener(requestReconcile);
    }
    _attached = false;
    _attachedGate = null;
    _init = (configure) => SentryFlutter.init(configure);
    _close = Sentry.close;
    _configured = () => SentryConfig.isConfigured;
  }
}
