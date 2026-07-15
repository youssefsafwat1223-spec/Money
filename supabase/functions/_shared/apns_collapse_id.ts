// Apple requires `apns-collapse-id` to be at most 64 bytes (UTF-8). The
// previous format (`qirsh-capture-<payloadId>`) assumed payloadId would
// always be a compact identifier, but iOS-Shortcut payloadIds are 64-char
// SHA-256 hex digests — `qirsh-capture-` (14 bytes) + 64 bytes = 78 bytes,
// unconditionally over the limit. Live evidence: every push for such a
// payload failed with `apns_400_InvalidCollapseId`.
//
// Fix: derive the collapse-id from a hash of the full payloadId rather than
// a prefix of the payloadId itself. Hashing (not truncating) matters because
// some payloadIds are human-readable diagnostic strings that can share a
// long common prefix (e.g. "codex_diagnose_ai_plain_transfer_ar_<ts>") — a
// prefix-truncation would collapse two genuinely different payloads into
// the same id. A hash's output is uniformly distributed regardless of the
// input's own structure, so collision risk stays negligible either way.
//
// This changes ONLY the APNs collapse identifier — never source_payload_id,
// never the payloadId used for relay/idempotency/dedup elsewhere.

const encoder = new TextEncoder();

const COLLAPSE_ID_PREFIX = 'qc-';
const MAX_COLLAPSE_ID_BYTES = 64;
const HEX_LENGTH = MAX_COLLAPSE_ID_BYTES - COLLAPSE_ID_PREFIX.length; // 61

export async function buildApnsCollapseId(payloadId: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', encoder.encode(payloadId));
  const hex = Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, '0'))
    .join('')
    .slice(0, HEX_LENGTH);
  const collapseId = `${COLLAPSE_ID_PREFIX}${hex}`;

  // Explicit assertion rather than trusting the construction silently — a
  // future change to the prefix/length constants must not silently regress
  // past Apple's limit.
  const byteLength = encoder.encode(collapseId).length;
  if (byteLength > MAX_COLLAPSE_ID_BYTES) {
    throw new Error(
      `apns-collapse-id exceeds ${MAX_COLLAPSE_ID_BYTES} bytes: got ${byteLength}`,
    );
  }
  return collapseId;
}
