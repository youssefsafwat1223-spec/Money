/// COUPONS Phase 3 — click preparation, claim verification, and the conversion
/// state machine. Extracted from the HTTP handlers so every decision is testable
/// without a database or a live provider.
///
/// ## The privacy shape, restated because it drives every function here
///
/// A click row has no user, no device, no IP and no user-agent. The network gets
/// a random `click_id` as its sub-id; the DEVICE keeps the plaintext claim token
/// and the server keeps only its SHA-256. So:
///
///   * the server cannot enumerate whose clicks are whose — there is nothing to
///     join on;
///   * a leaked click table lets nobody claim anybody's conversion, because the
///     plaintext exists only on the phone that made it;
///   * a device proves a click was its own by presenting the token, which is the
///     only capability anyone has over that row.
///
/// That last point is why status lookups take a token rather than an id.

/** A prepared click: what the server stores, and what the device keeps. */
export interface PreparedClick {
  clickId: string;
  /** Returned ONCE, to the device. Never stored server-side in this form. */
  claimToken: string;
  /** SHA-256 of the token. This is what the server stores. */
  claimSecretHash: string;
  /** The provider URL with the sub-id attached. */
  trackingUrl: string;
}

/** Conversion status as the device may see it. */
export type PublicClickStatus = 'pending' | 'confirmed' | 'declined' | 'unknown';

const HEX64 = /^[0-9a-f]{64}$/;

export async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

/**
 * Mint a click id and a one-time claim token.
 *
 * The token is 32 random bytes, not a hash of anything: deriving it from the
 * click id or a timestamp would make it guessable from data the network already
 * holds, and the whole point is that only the device can present it.
 */
export async function prepareClick(
  destinationUrl: string,
  subIdParam: string,
): Promise<PreparedClick> {
  if (!destinationUrl.startsWith('https://')) {
    // A tracked click that downgrades the connection would be worse than an
    // untracked one: the user gets neither privacy nor the offer safely.
    throw new Error('insecure_destination');
  }
  const clickId = crypto.randomUUID();
  const raw = crypto.getRandomValues(new Uint8Array(32));
  const claimToken = Array.from(raw).map((b) => b.toString(16).padStart(2, '0')).join('');

  const url = new URL(destinationUrl);
  // The sub-id is the click id and NOTHING else. Networks accept arbitrary
  // sub-ids and it is tempting to pack a user or install reference in for
  // convenience; that would hand a commercial partner a stable identifier for a
  // person, which is exactly what this design refuses to do.
  url.searchParams.set(subIdParam, clickId);

  return {
    clickId,
    claimToken,
    claimSecretHash: await sha256Hex(claimToken),
    trackingUrl: url.toString(),
  };
}

/**
 * Decide what a device is told about its click.
 *
 * `unknown` is deliberately overloaded: it covers a click we never had, a click
 * that expired, and a token that does not match. A caller cannot distinguish
 * them, so a wrong or guessed token learns NOTHING — not even whether that click
 * id exists. Any more helpful answer would turn this endpoint into an oracle for
 * enumerating other people's clicks.
 */
export function publicStatusFor(
  row: { claim_secret_hash: string; expires_at: string } | null,
  presentedTokenHash: string,
  conversionStatus: string | null,
  now: Date = new Date(),
): PublicClickStatus {
  if (row == null) return 'unknown';
  if (!HEX64.test(presentedTokenHash)) return 'unknown';
  if (!timingSafeEqualHex(row.claim_secret_hash, presentedTokenHash)) return 'unknown';
  if (new Date(row.expires_at) <= now) return 'unknown';

  switch (conversionStatus) {
    case 'approved':
      return 'confirmed';
    case 'rejected':
    case 'returned':
    case 'cancelled':
      return 'declined';
    case 'pending':
      return 'pending';
    default:
      // A verified click with no conversion yet. NOT `unknown`: the device
      // legitimately holds this click and is entitled to know the network has
      // not reported on it.
      return 'pending';
  }
}

/**
 * Constant-time comparison of two hex digests.
 *
 * Both are fixed-length hashes, so length alone leaks nothing — but the compare
 * still must not short-circuit, or the time to reject reveals how many leading
 * characters were right, and a token becomes brute-forceable one nibble at a
 * time.
 */
export function timingSafeEqualHex(a: string, b: string): boolean {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/** A provider-neutral conversion event, after an adapter has normalized it. */
export interface ConversionEvent {
  externalConversionId: string;
  /** The sub-id the network echoes back — our click id, when it survived. */
  clickId: string | null;
  status: 'pending' | 'approved' | 'rejected' | 'returned' | 'cancelled';
  orderAmountMinor?: number | null;
  orderCurrency?: string | null;
  commissionAmountMinor?: number | null;
  commissionCurrency?: string | null;
  providerDiscountMinor?: number | null;
  providerDiscountCurrency?: string | null;
  occurredAt?: string | null;
}

export type ConversionRejection =
  | 'missing_conversion_id'
  | 'bad_status'
  | 'amount_without_currency'
  | 'negative_amount'
  | 'bad_click_id';

const ISO_CURRENCY = /^[A-Z]{3}$/;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Validate a conversion before it touches the ledger.
 *
 * Mirrors the 0097 CHECKs — including the one that constraint got wrong at
 * first: an amount with a NULL currency passes `amount IS NULL OR currency ~
 * '...'` because the regex evaluates to NULL rather than FALSE. The explicit
 * null test here is deliberate for the same reason.
 */
export function validateConversion(event: ConversionEvent): ConversionRejection[] {
  const out: ConversionRejection[] = [];
  if (typeof event.externalConversionId !== 'string' ||
      event.externalConversionId.trim().length === 0) {
    out.push('missing_conversion_id');
  }
  const known = ['pending', 'approved', 'rejected', 'returned', 'cancelled'];
  if (!known.includes(event.status)) out.push('bad_status');

  const pairs: Array<[number | null | undefined, string | null | undefined]> = [
    [event.orderAmountMinor, event.orderCurrency],
    [event.commissionAmountMinor, event.commissionCurrency],
    [event.providerDiscountMinor, event.providerDiscountCurrency],
  ];
  for (const [amount, currency] of pairs) {
    if (amount == null) continue;
    if (amount < 0) out.push('negative_amount');
    if (currency == null || !ISO_CURRENCY.test(currency)) out.push('amount_without_currency');
  }

  if (event.clickId != null && !UUID_RE.test(event.clickId)) out.push('bad_click_id');
  return out;
}

/**
 * Whether a status transition should be applied.
 *
 * Networks deliver out of order — a `returned` can arrive before the `approved`
 * it reverses, especially after an outage replays a backlog. Applying blindly by
 * arrival would leave a returned conversion sitting at `approved`, i.e. counting
 * revenue that was clawed back.
 *
 * So terminal-negative states are STICKY: once something is returned, rejected
 * or cancelled, a later `approved` for the same conversion does not resurrect
 * it. The reverse direction is always allowed, because a clawback is news.
 */
export function shouldApplyTransition(current: string, incoming: string): boolean {
  if (current === incoming) return false;
  const terminalNegative = ['returned', 'rejected', 'cancelled'];
  if (terminalNegative.includes(current) && !terminalNegative.includes(incoming)) {
    return false;
  }
  // `pending` is a STARTING state, never news about a conversion that has
  // already moved on. Networks deliver out of order — and receipts are pruned
  // after 180 days while conversions live forever, so an old replayed `pending`
  // can arrive with no replay guard left to stop it. Applying it would demote a
  // settled `approved` back to pending and overwrite its amounts: a confirmed
  // commission silently un-confirmed by a stale message.
  if (incoming === 'pending') return false;
  return true;
}
