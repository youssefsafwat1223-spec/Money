// MALI-068n §11 — one authoritative received-time contract for a captured
// message.
//
// The native EPOCH (an SMS's `timestampMillis`, or the share time) is the
// authority. A formatted ISO string is only a LEGACY fallback for queue items
// written before the epoch field existed — it is never the primary source, and
// a locale-formatted string is never parsed as authority. A missing/invalid
// value resolves to `null` (a typed "unknown"), NEVER silently to `now`:
// stamping `now` would rewrite the transaction's place in financial history.
library;

/// Resolves the authoritative UTC received-time.
///
/// [epochMs] is the native millisecond epoch (preferred). [isoString] is the
/// legacy ISO-8601 fallback. Returns null when neither yields a valid instant —
/// callers apply their own documented policy for an unknown time (e.g. leave it
/// unset) rather than defaulting to the current time.
DateTime? resolveCapturedReceivedAt({int? epochMs, String? isoString}) {
  if (epochMs != null && epochMs > 0) {
    return DateTime.fromMillisecondsSinceEpoch(epochMs, isUtc: true);
  }
  final iso = isoString?.trim();
  if (iso != null && iso.isNotEmpty) {
    return DateTime.tryParse(iso)?.toUtc();
  }
  return null;
}
