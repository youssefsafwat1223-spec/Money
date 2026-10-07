/// Whether a durable native capture drained by the app may be sent to AI as a
/// last-resort local-parse fallback.
///
/// `sent` means the share extension / App Intent already showed this capture's
/// notification, and the server has no suppress-push option, so only a capture
/// that the backend FAILED to analyse (stored `sent` with a `failureReason`)
/// qualifies: the in-app AI call is the only analysis it will ever get, and it
/// produces no notification. `pendingSend` items (no banner yet) keep using the
/// retry path and never reach this rule.
///
/// Both [flagEnabled] (kill switch) and [aiAllowed] (consent, read fresh for
/// this message) must hold, so a revoked consent never re-sends.
///
/// A 409 (`http(409)`: `capture_owner_conflict` / `capture_owner_mismatch`) is
/// the server REFUSING to attribute this capture to the current owner (Astra H1:
/// an ownerless upload after an owner transition). That refusal is final: the
/// item never reaches AI, only the local deterministic parser.
bool nativeCaptureMayUseAiFallback({
  required String? status,
  required String? failureReason,
  required bool flagEnabled,
  required bool aiAllowed,
}) {
  final reason = failureReason?.trim() ?? '';
  return status == 'sent' &&
      reason.isNotEmpty &&
      reason != 'http(409)' &&
      flagEnabled &&
      aiAllowed;
}
