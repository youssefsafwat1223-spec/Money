// MALI-032 — outbound telemetry boundary (Sentry `beforeSend` +
// `beforeBreadcrumb`).
//
// Every event and breadcrumb that Sentry would transmit passes through here
// first. The boundary is an ALLOWLIST: a field survives only if we can name it
// as safe. Concretely, for an event we
//
//   * drop every exception's free-form message (keeping the class name for
//     triage, or a structured [TelemetryError.code] when one is present),
//   * strip local variables from every stack frame,
//   * drop ALL breadcrumbs, threads, the request, and the user,
//   * keep only allowlisted `tags` / `extra` keys (values still redacted),
//   * keep only the standard `device`/`os`/`app`/`runtime` context blocks,
//   * clear the server/host name.
//
// This is deliberately aggressive: for a financial app, an exception class name
// plus a stack trace plus a structured code is enough to triage, and no
// free-form text — which is where SMS bodies, merchant names, amounts, account
// numbers and tokens hide — is ever worth the leakage risk.
//
// LIMITATION (documented, not hidden): this Dart boundary does NOT run on
// crashes captured by the native (iOS/Android) SDKs — those are serialized and
// sent by the native layer on the next launch. We mitigate that in [main] by
// disabling native auto-breadcrumbs and relying on the architecture (financial
// data lives in Dart / the encrypted DB, not in native crash payloads). Full
// native scrubbing parity is tracked as residual for the native SDK config.
library;

import 'package:sentry_flutter/sentry_flutter.dart';

import 'privacy_redactor.dart';
import 'telemetry_error.dart';

/// Pure, stateless sanitizers wired into `SentryOptions` in [main].
class TelemetrySanitizer {
  const TelemetrySanitizer._();

  /// `options.beforeSend` — returns a sanitized copy of [event].
  static SentryEvent sanitizeEvent(SentryEvent event) {
    return event.copyWith(
      exceptions: _sanitizeExceptions(event.exceptions),
      threads: const <SentryThread>[],
      message: _sanitizeMessage(event.message),
      breadcrumbs: const <Breadcrumb>[],
      request: SentryRequest(),
      // copyWith(user: null) would KEEP the original user, so replace it with a
      // sentinel: no real id/email/ip/username survives. (SentryUser also
      // requires at least one non-null identifying field.)
      user: SentryUser(id: PrivacyRedactor.redacted),
      extra: _allowlistExtra(event.extra),
      tags: _allowlistTags(event.tags),
      contexts: _sanitizeContexts(event.contexts),
      serverName: '',
    );
  }

  /// `options.beforeBreadcrumb` — keeps only the SHAPE of a breadcrumb
  /// (category / type / level / timestamp) and drops its message and data,
  /// which is where URLs, SMS text, amounts and merchant names would ride.
  static Breadcrumb? sanitizeBreadcrumb(Breadcrumb? crumb) {
    if (crumb == null) return null;
    return crumb.copyWith(
      message: '',
      data: <String, dynamic>{},
    );
  }

  // ── internals ─────────────────────────────────────────────────────────────

  static List<SentryException>? _sanitizeExceptions(
    List<SentryException>? exceptions,
  ) {
    if (exceptions == null) return null;
    return <SentryException>[for (final e in exceptions) _sanitizeException(e)];
  }

  static SentryException _sanitizeException(SentryException e) {
    final throwable = e.throwable;
    // A structured error may surface its stable code; everything else has its
    // free-form message dropped. The exception `type` (class name) is retained.
    final value =
        throwable is TelemetryError ? throwable.code : PrivacyRedactor.redacted;
    return e.copyWith(
      value: value,
      stackTrace: _sanitizeStackTrace(e.stackTrace),
    );
  }

  static SentryStackTrace? _sanitizeStackTrace(SentryStackTrace? st) {
    if (st == null) return null;
    // Keep code locations (function / package path / line) for triage; strip
    // any captured local variables, which could hold runtime values.
    return st.copyWith(
      frames: <SentryStackFrame>[
        for (final f in st.frames) f.copyWith(vars: <String, String>{}),
      ],
    );
  }

  static SentryMessage? _sanitizeMessage(SentryMessage? message) {
    if (message == null) return null;
    // Drop the formatted text, template AND params (params can hold values).
    return SentryMessage(PrivacyRedactor.redacted);
  }

  static Map<String, String> _allowlistTags(Map<String, String>? tags) {
    final out = <String, String>{};
    if (tags == null) return out;
    for (final entry in tags.entries) {
      if (PrivacyRedactor.allowedTagKeys.contains(entry.key)) {
        out[entry.key] = PrivacyRedactor.redactText(entry.value);
      }
    }
    return out;
  }

  static Map<String, dynamic> _allowlistExtra(Map<String, dynamic>? extra) {
    final out = <String, dynamic>{};
    if (extra == null) return out;
    for (final entry in extra.entries) {
      if (PrivacyRedactor.allowedExtraKeys.contains(entry.key)) {
        out[entry.key] = PrivacyRedactor.redactValue(entry.value);
      }
    }
    return out;
  }

  static Contexts _sanitizeContexts(Contexts? contexts) {
    final out = Contexts();
    if (contexts == null) return out;
    for (final key in PrivacyRedactor.allowedContextKeys) {
      final value = contexts[key];
      if (value != null) out[key] = value;
    }
    return out;
  }
}
