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

Deno.serve(async (req) => {
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

  const supabase = serviceClient();
  const payloadHash = await sha256Hex(raw);

  // CLAIM FIRST. The unique (network_key, external_event_id) constraint is the
  // replay guard, and it has to win before any state changes.
  const eventId = String(body.event_id ?? event.externalConversionId);
  const { error: claimError } = await supabase
    .from('affiliate_webhook_receipts')
    .insert({
      network_key: networkKey,
      external_event_id: eventId,
      payload_hash: payloadHash,
    });
  if (claimError) {
    // Already seen. 200, not an error: a network that gets a 4xx will retry
    // forever, and this is the correct terminal outcome for a duplicate.
    safeLog({ event: 'affiliate_postback_replay', fn: 'affiliate-postback', correlation_id: cid });
    return json({ ok: true, duplicate: true });
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
      .update({
        status: event.status,
        click_id: event.clickId ?? undefined,
        order_amount_minor: event.orderAmountMinor,
        order_currency: event.orderCurrency,
        commission_amount_minor: event.commissionAmountMinor,
        commission_currency: event.commissionCurrency,
        provider_discount_minor: event.providerDiscountMinor,
        provider_discount_currency: event.providerDiscountCurrency,
      })
      .eq('id', existing.id);
    if (error) resultCode = 'update_failed';
  } else {
    resultCode = 'ignored_stale';
  }

  await supabase
    .from('affiliate_webhook_receipts')
    .update({ processed_at: new Date().toISOString(), result_code: resultCode })
    .eq('network_key', networkKey)
    .eq('external_event_id', eventId);

  safeLog({
    event: 'affiliate_postback_processed',
    fn: 'affiliate-postback',
    correlation_id: cid,
    result: resultCode,
  });
  return json({ ok: true });
});
