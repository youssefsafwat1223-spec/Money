// COUPONS Phase 2 — the content fingerprint used for ingestion dedupe.
//
// A provider feed republishes the same offer every run. Without a content hash,
// each run either creates a duplicate review item — and the queue becomes noise
// that reviewers stop reading — or blindly overwrites, losing the fact that
// nothing actually changed.
//
// So: same content, same fingerprint, no new review item. Changed content, new
// fingerprint, back into the queue. That second half matters as much as the
// first — a provider silently changing a discount from 20% to 5% on a PUBLISHED
// offer must not slip through as "already seen".

import type { NormalizedOffer } from './types.ts';

/** ASCII unit separator. It cannot appear in provider copy, so "ab"+"c"
 *  and "a"+"bc" cannot collide into the same canonical string. */
const SEP = String.fromCharCode(0x1f);

/**
 * A deterministic hash of everything a REVIEWER would care about.
 *
 * Deliberately excludes: the provider's ids (identity, not content — they are
 * the lookup key, and hashing them would make every offer unique), and
 * last-seen timestamps (they change every run by definition, which would defeat
 * the whole mechanism).
 *
 * Deliberately INCLUDES the structured value and the window. A cap appearing, a
 * minimum spend changing, or an expiry moving are all things a human approved a
 * specific version of.
 */
export async function offerFingerprint(offer: NormalizedOffer): Promise<string> {
  // A fixed field ORDER, not JSON.stringify of the object: key order in a JS
  // object is insertion-ordered, so two adapters building the same offer with
  // fields assigned in a different sequence would hash differently and dedupe
  // would silently stop working.
  const parts = [
    offer.titleAr,
    offer.titleEn ?? '',
    offer.descriptionAr,
    offer.descriptionEn ?? '',
    offer.termsAr ?? '',
    offer.redemptionType,
    offer.code ?? '',
    offer.url ?? '',
    offer.benefitType ?? '',
    String(offer.discountBps ?? ''),
    String(offer.fixedAmountMinor ?? ''),
    String(offer.minSpendMinor ?? ''),
    String(offer.maxSavingMinor ?? ''),
    offer.benefitCurrency ?? '',
    // Sorted: a provider reordering its market list is not a content change.
    [...offer.markets].sort().join(','),
    offer.validFrom ?? '',
    offer.validUntil ?? '',
  ];
  // A unit separator (U+001F) rather than a printable delimiter: it cannot
  // appear in provider copy, so "ab" + "c" and "a" + "bc" cannot collide into
  // the same canonical string.
  const canonical = parts.join(SEP);
  const digest = await crypto.subtle.digest(
    'SHA-256',
    new TextEncoder().encode(canonical),
  );
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}
