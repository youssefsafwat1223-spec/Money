// COUPONS Phase 3 — the conversion postback receiver.
//
// A network tells us a sale happened. This is the only path by which a
// conversion enters the system, and it is the one place where getting replay,
// ordering or authentication wrong costs money — ours or, through a savings
// figure, the user's trust.
//
// ## No network is contracted, so the signature check is a SEAM, not a stub
//
// Every network signs differently: HMAC over the body, HMAC over a canonical
// string, a shared bearer, mTLS. `verifySignature` is deliberately a per-network
// switch with NO default-allow branch — an unknown network is rejected, so
// wiring a real provider means adding a case, not removing a bypass. Shipping a
// permissive default "until we know" is how an unauthenticated endpoint reaches
// production.
//
// ## Claim before process
//
// The receipt row is inserted FIRST, and its unique (network, event id)
// constraint is what stops a replay. A network will resend — twice, or for days
// after an outage, or out of order — and processing a resent `approved` twice
// would double-count revenue. Losing the race on that insert means somebody else
// already has this event, and we stop.

import { corsHeaders, serviceClient } from '../_shared/capture_auth.ts';
import { correlationId, readJsonBody, safeLog } from '../_shared/ai_endpoint.ts';
import {
  type ConversionEvent,
  sha256Hex,
  shouldApplyTransition,
  timingSafeEqualHex,
  validateConversion,
} from '../_shared/affiliate/attribution.ts';

const MAX_BODY_BYTES = 16384;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...corsHeaders },
  });
}

/**
 * Per-network signature verification.
 *
 * No default-allow. An unknown network key returns false, so an unconfigured or
 * misconfigured provider is rejected rather than trusted.
 */
async function verifySignature(
  networkKey: string,
  rawBody: string,
  headers: Headers,
): Promise<boolean> {
  switch (networkKey) {
    case 'fixture': {
      // The fixture network signs with a plain SHA-256 of secret + body. Not a
      // real scheme — it exists so the whole postback path is exercisable end to
      // end before a contract exists, and it still requires a configured secret,
      // so it cannot be called by anyone who does not have one.
      const secret = Deno.env.get('AFFILIATE_FIXTURE_POSTBACK_SECRET') ?? '';
      if (!secret) return false;
      const presented = headers.get('x-qirsh-signature') ?? '';
      if (!/^[0-9a-f]{64}$/.test(presented)) return false;
      return timingSafeEqualHex(await sha256Hex(secret + rawBody), presented);
    }
    default:
      return false;
  }
}

/** Maps a provider payload onto the provider-neutral event. */
function normalize(body: Record<string, unknown>): ConversionEvent {
  const num = (v: unknown) => (typeof v === 'number' ? Math.round(v) : null);
  const str = (v: unknown) =>
    typeof v === 'string' && v.trim().length > 0 ? v.trim() : null;
  return {
    externalConversionId: str(body.conversion_id) ?? '',
    clickId: str(body.sub_id),
    status: (str(body.status) ?? 'pending') as ConversionEvent['status'],
    orderAmountMinor: num(body.order_amount_minor),
    orderCurrency: str(body.order_currency)?.toUpperCase() ?? null,
    commissionAmountMinor: num(body.commission_amount_minor),
    commissionCurrency: str(body.commission_currency)?.toUpperCase() ?? null,
    providerDiscountMinor: num(body.discount_amount_minor),
    providerDiscountCurrency: str(body.discount_currency)?.toUpperCase() ?? null,
    occurredAt: str(body.occurred_at),
  };
}

/// The handler, exported so it can be exercised BEHAVIOURALLY.
///
/// `Deno.serve` below is the only production entry point and simply calls this.
/// The Supabase client is injectable purely so tests can drive the claim /
/// write / release paths against a fake — the ordering bugs this function was
/// fixed for are invisible to any test that only reads source text.
export async function handlePostback(
  req: Request,
  makeClient: () => ReturnType<typeof serviceClient> = serviceClient,
): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  const cid = correlationId();

  const url = new URL(req.url);
  const networkKey = (url.searchParams.get('network') ?? '').trim();
  if (!/^[a-z0-9_]{2,40}$/.test(networkKey)) {
    return json({ error: 'unknown_network' }, 404);
  }

  // Read the raw body ONCE: signatures are over exact bytes, and re-serialising
  // parsed JSON would change key order and whitespace and never verify.
  const raw = await req.text();
  if (raw.length > MAX_BODY_BYTES) return json({ error: 'payload_too_large' }, 413);

  if (!await verifySignature(networkKey, raw, req.headers)) {
    // No detail. A prober learns only that this endpoint exists.
    safeLog({ event: 'affiliate_postback_rejected', fn: 'affiliate-postback', correlation_id: cid });
    return json({ error: 'unauthorized' }, 401);
  }

  let body: Record<string, unknown>;
  try {
    body = JSON.parse(raw) as Record<string, unknown>;
  } catch {
    return json({ error: 'invalid_payload' }, 400);
  }

  const event = normalize(body);
  const problems = validateConversion(event);
  if (problems.length > 0) {
    safeLog({
      event: 'affiliate_postback_invalid',
      fn: 'affiliate-postback',
      correlation_id: cid,
      // Codes only. A provider's own error text can echo the request that
      // produced it, and that request carried a credential.
      result: problems.join(','),
    });
    return json({ error: 'invalid_payload' }, 400);
  }

  const supabase = makeClient();
  const payloadHash = await sha256Hex(raw);

  // CLAIM FIRST. The unique (network_key, external_event_id) constraint is the
  // replay guard, and it has to win before any state changes.
  // The receipt key must identify a DELIVERY, not a conversion.
  //
  // This fell back to externalConversionId when a network sent no event_id —
  // which makes every status change for one conversion share a receipt key. The
  // first delivery (pending) processes; the later `approved` then hits the claim
  // conflict, sees processed_at set, and returns 200 duplicate WITHOUT applying
  // the transition. The conversion sticks at pending forever and the provider is
  // told success: exactly the silent, irrecoverable 200 this function was fixed
  // to eliminate, reintroduced through the fallback.
  //
  // With no provider event_id, the delivery identity is the conversion plus the
  // status it carries plus the payload digest, so a genuine replay still
  // collides while a real status change does not.
  const eventId = body.event_id != null
    ? String(body.event_id)
    : `${event.externalConversionId}:${event.status}:${payloadHash.slice(0, 16)}`;
  // The receipt id is captured so every later write targets THE CLAIM THIS
  // REQUEST OWNS, never "whatever row currently matches this event key".
  let claimedReceiptId: string | null = null;
  const { data: claimRow, error: claimError } = await supabase
    .from('affiliate_webhook_receipts')
    .insert({
      network_key: networkKey,
      external_event_id: eventId,
      payload_hash: payloadHash,
    })
    .select('id')
    .maybeSingle();
  claimedReceiptId = (claimRow?.id as string | undefined) ?? null;
  if (claimError) {
    // ONLY a unique violation means "already claimed". Any other error — a
    // connection failure, RLS, a CHECK violation — previously fell through to
    // the resume path, where the follow-up SELECT found nothing and the request
    // proceeded to write a conversion HOLDING NO CLAIM AT ALL, leaving that
    // event with no replay guard and still returning 200.
    if (claimError.code !== '23505') {
      safeLog({
        event: 'affiliate_postback_claim_failed',
        fn: 'affiliate-postback',
        correlation_id: cid,
        result: claimError.code ?? 'unknown',
      });
      return json({ error: 'claim_failed', retry: true }, 503);
    }
    // The claim already exists — but "claimed" is NOT the same as "processed".
    //
    // A previous attempt can have inserted the receipt and then died before
    // writing the conversion (an error, a timeout, the isolate being torn
    // down). Returning `duplicate` for that case is how a REAL conversion gets
    // silently dropped forever: the provider sees 200, never retries, and no
    // conversion row exists. `processed_at` is the discriminator.
    const { data: claimed, error: claimReadError } = await supabase
      .from('affiliate_webhook_receipts')
      .select('id, processed_at')
      .eq('network_key', networkKey)
      .eq('external_event_id', eventId)
      .maybeSingle();

    // A transient READ failure must not be read as "unprocessed". Treating it
    // that way resumed, hit the conversion unique constraint, and then DELETED
    // the receipt of an already-processed event — destroying a real replay
    // guard because a SELECT blipped.
    if (claimReadError) {
      safeLog({
        event: 'affiliate_postback_claim_read_failed',
        fn: 'affiliate-postback',
        correlation_id: cid,
      });
      return json({ error: 'claim_read_failed', retry: true }, 503);
    }

    claimedReceiptId = (claimed?.id as string | undefined) ?? null;

    if (claimed?.processed_at != null) {
      // Genuinely already processed. 200, not an error: a network that gets a
      // 4xx will retry forever, and this is the correct terminal outcome.
      safeLog({ event: 'affiliate_postback_replay', fn: 'affiliate-postback', correlation_id: cid });
      return json({ ok: true, duplicate: true });
    }
    // Unprocessed claim: RESUME. The conversion write below is keyed on
    // (network_key, external_conversion_id) and checks for an existing row
    // first, so resuming cannot duplicate it.
    safeLog({ event: 'affiliate_postback_resume', fn: 'affiliate-postback', correlation_id: cid });
  }

  const { data: existing } = await supabase
    .from('affiliate_conversions')
    .select('id, status')
    .eq('network_key', networkKey)
    .eq('external_conversion_id', event.externalConversionId)
    .maybeSingle();

  let resultCode = 'applied';
  if (existing == null) {
    const { error } = await supabase.from('affiliate_conversions').insert({
      network_key: networkKey,
      external_conversion_id: event.externalConversionId,
      click_id: event.clickId,
      status: event.status,
      order_amount_minor: event.orderAmountMinor,
      order_currency: event.orderCurrency,
      commission_amount_minor: event.commissionAmountMinor,
      commission_currency: event.commissionCurrency,
      provider_discount_minor: event.providerDiscountMinor,
      provider_discount_currency: event.providerDiscountCurrency,
      occurred_at: event.occurredAt,
    });
    if (error) {
      safeLog({ event: 'affiliate_conversion_insert_failed', fn: 'affiliate-postback', correlation_id: cid });
      resultCode = 'insert_failed';
    }
  } else if (shouldApplyTransition(existing.status as string, event.status)) {
    // Terminal-negative states are sticky. Networks deliver out of order,
    // especially replaying a backlog after an outage, and applying by arrival
    // would leave a returned conversion sitting at approved — counting revenue
    // that was clawed back.
    const { error } = await supabase
      .from('affiliate_conversions')
      // `?? undefined` on EVERY money field, not just click_id.
      //
      // PostgREST writes an explicit null but omits an undefined key. A
      // `returned` or `rejected` event routinely carries no amounts, and
      // passing those through as null ERASED the recorded commission of the
      // very conversion being clawed back — destroying the number needed to
      // reconcile the clawback. A status change must not silently blank the
      // money it refers to; absent means "unchanged", not "zero".
      .update({
        status: event.status,
        click_id: event.clickId ?? undefined,
        order_amount_minor: event.orderAmountMinor ?? undefined,
        order_currency: event.orderCurrency ?? undefined,
        commission_amount_minor: event.commissionAmountMinor ?? undefined,
        commission_currency: event.commissionCurrency ?? undefined,
        provider_discount_minor: event.providerDiscountMinor ?? undefined,
        provider_discount_currency: event.providerDiscountCurrency ?? undefined,
      })
      .eq('id', existing.id);
    if (error) resultCode = 'update_failed';
  } else {
    resultCode = 'ignored_stale';
  }

  // A FAILED conversion write must not consume the event.
  //
  // Previously this marked the receipt processed and returned 200 even when the
  // insert or update had failed, so the provider treated a lost conversion as
  // delivered and never retried. Real money, irrecoverably dropped.
  //
  // Release the claim and answer 5xx so the network retries. Releasing is safe:
  // no conversion row was written, so the retry cannot duplicate one, and the
  // (network_key, external_event_id) uniqueness still guards genuine replays
  // once a write has actually succeeded.
  if (resultCode === 'insert_failed' || resultCode === 'update_failed') {
    // Delete by the claim THIS request owns. Keyed by (network_key,
    // external_event_id) instead, a concurrent delivery that lost the
    // conversion-insert race would delete the winner's claim — leaving the
    // event with a written conversion and no replay guard.
    if (claimedReceiptId != null) {
      await supabase
        .from('affiliate_webhook_receipts')
        .delete()
        .eq('id', claimedReceiptId);
    }
    safeLog({
      event: 'affiliate_postback_failed',
      fn: 'affiliate-postback',
      correlation_id: cid,
      result: resultCode,
    });
    // 503: transient by contract. The provider must retry this event.
    return json({ error: 'conversion_write_failed', retry: true }, 503);
  }

  if (claimedReceiptId != null) {
    await supabase
      .from('affiliate_webhook_receipts')
      .update({ processed_at: new Date().toISOString(), result_code: resultCode })
      .eq('id', claimedReceiptId);
  }

  safeLog({
    event: 'affiliate_postback_processed',
    fn: 'affiliate-postback',
    correlation_id: cid,
    result: resultCode,
  });
  return json({ ok: true });
}

Deno.serve((req) => handlePostback(req));
