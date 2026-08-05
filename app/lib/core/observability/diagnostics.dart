// MALI-039 / MALI-075n — privacy-safe diagnostic logging.
//
// `debugPrint` is NOT stripped in release builds; its output reaches the
// platform log (os_log / logcat), which is readable off-device. Any exception
// `toString()` can carry sensitive data — a Drift SqliteException echoing bound
// values, a parse error echoing SMS text, a token in a network error.
//
// Two layers enforce the invariant "no raw sensitive data in a log line":
//   1. [Diag.installRedactingSink] rewires the global `debugPrint` so EVERY
//      line — from any call site, plugin, or future code — is redacted (via the
//      shared [PrivacyRedactor]) and length-bounded before it is emitted, in
//      debug AND release. Installed once from `main`.
//   2. [Diag.error] / [Diag.log] are the sanctioned structured API for
//      intentional diagnostics; their output is also redacted (idempotently) by
//      layer 1, so a missed call site can never leak.
library;

import 'package:flutter/foundation.dart';

import 'privacy_redactor.dart';

/// Privacy-safe diagnostic logging. See library docs.
class Diag {
  const Diag._();

  /// Upper bound on a single emitted line, so a pathological error string
  /// cannot dump an unbounded payload to the platform log.
  static const int maxLineLength = 240;

  /// Redacts and length-bounds a single log line. Pure and idempotent enough to
  /// run twice (structured call + global sink) without corrupting output.
  static String redactLine(String input) {
    final redacted = PrivacyRedactor.redactText(input);
    if (redacted.length <= maxLineLength) return redacted;
    final kept = redacted.substring(0, maxLineLength);
    return '$kept… [+${redacted.length - maxLineLength} chars]';
  }

  /// Rewires the global `debugPrint` to redact + bound every line while
  /// delegating to the original (throttled) sink. Call once, early in `main`.
  static void installRedactingSink() {
    final DebugPrintCallback previous = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      previous(message == null ? null : redactLine(message), wrapWidth: wrapWidth);
    };
  }

  /// Emits a redacted, bounded diagnostic line under [tag].
  static void log(String tag, String message) {
    debugPrint('$tag ${redactLine(message)}');
  }

  /// Emits a caught [error] under [tag], redacted and bounded. Prefer throwing
  /// or reporting a `TelemetryError` where a stable code is signal enough.
  static void error(String tag, Object error) {
    debugPrint('$tag: ${redactLine(error.toString())}');
  }
}
