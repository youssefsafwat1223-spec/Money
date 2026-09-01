// COUPONS Phase 3 — mint a tracked click.
//
// The device asks for a tracking URL; it gets one, plus a click id and a
// one-time claim token that only it will ever hold. The server keeps the token's
// SHA-256 and nothing that could say whose click this was.
//
// ═══════════════════════════════════════════════════════════════════════════
// THIS ENDPOINT AUTHENTICATES THE CALLER AND THEN DELIBERATELY FORGETS THEM.
// ═══════════════════════════════════════════════════════════════════════════
//
// Identity is resolved — an unauthenticated caller could otherwise mint clicks
// for free and burn a partner's sub-id space — and the rate limit is keyed on
// it. But the identity is used ONLY for those two decisions. It is never written
// to `affiliate_clicks`, which has no column that could hold it, so the row that
// survives the request cannot be traced back to the person who made it.
//
// That asymmetry is the whole design: authenticate to decide whether to act,
// then persist as little as the action actually needs.
//
// ## Failure is not an error the user should feel
//
// If this endpoint is down, rate-limited, or the flag is off, the CLIENT falls
// back to launching the plain merchant URL untracked. The user gets to the offer
// either way; we simply do not earn on it. A tracked click is a revenue
// optimisation, and treating it as a precondition for the user's own purchase
// would be the wrong trade.

import { bumpCaptureEndpointRateLimit, corsHeaders, readString, serviceClient } from '../_shared/capture_auth.ts';
import {
  apiError,
  correlationId,
  latencyBucket,
  consentError,
  readJsonBody,
  resolveVerifiedIdentity,
  safeLog,
  schemaError,
} from '../_shared/ai_endpoint.ts';
import { prepareClick } from '../_shared/affiliate/attribution.ts';

const MAX_BODY_BYTES = 4096;
/// Generous for a human, restrictive for a script. A person cannot click 300
/// offers a day; something doing so is burning a partner's sub-id space.
const RATE_LIMIT_PER_DAY = 300;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...corsHeaders },
  });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  const cid = correlationId();
  const startedAt = Date.now();

  const supabase = serviceClient();

  const bodyRes = await readJsonBody(req, MAX_BODY_BYTES);
  if (!bodyRes.ok) return apiError(bodyRes.code, { correlationId: cid });
  const body = bodyRes.body as Record<string, unknown>;

  const schemaProblem = schemaError(body, cid);
  if (schemaProblem) return schemaProblem;

  const identity = await resolveVerifiedIdentity(req, supabase, body, cid);
  if (!identity.ok) return identity.response;

  // Cloud-processing consent, enforced server-side as well as on the client.
  // A tracked click sends a request that the server records; a user who has
  // declined cloud processing has not agreed to that, and the client's own gate
  // is not something the server should rely on.
  const consentBad = consentError(identity.identity, 'cloud', cid);
  if (consentBad) return consentBad;

  const limited = await bumpCaptureEndpointRateLimit(
    supabase,
    identity.identity.ownerKey,
    'prepare-affiliate-click',
    RATE_LIMIT_PER_DAY,
  );
  if (limited) return apiError('rate_limited', { correlationId: cid, retryable: true });

  const couponId = readString(body, 'coupon_id');
  if (!couponId) return apiError('invalid_payload', { correlationId: cid });

  // The destination comes from the CATALOG, never from the request. A
  // caller-supplied URL would make this an open redirect that also signs its
  // traffic with our affiliate id — sending users anywhere while attributing the
  // click to us.
  const { data: coupon } = await supabase
    .from('coupons')
    .select('id, partner_url, is_active, merchant_id')
    .eq('id', couponId)
    .maybeSingle();
  if (!coupon?.partner_url || coupon.is_active !== true) {
    return apiError('invalid_payload', { correlationId: cid });
  }

  // Which network, and how it wants its sub-id. Absent means this coupon is not
  // an affiliate offer at all — the client should have launched it directly, and
  // minting a click for it would record attribution that can never resolve.
  const { data: source } = await supabase
    .from('affiliate_offer_sources')
    .select('id, affiliate_programs(affiliate_networks(network_key, capabilities, status))')
    .eq('coupon_id', couponId)
    .maybeSingle();

  const network = (source as unknown as {
    affiliate_programs?: {
      affiliate_networks?: {
        network_key: string;
        capabilities: Record<string, unknown> | null;
        status: string;
      } | null;
    } | null;
  } | null)?.affiliate_programs?.affiliate_networks ?? null;

  if (!network || network.status === 'disabled') {
    // Not tracked, and that is a normal outcome rather than a failure. The
    // client launches the plain URL.
    return json({ tracked: false, url: coupon.partner_url });
  }

  const subIdParam = typeof network.capabilities?.subid_param === 'string'
    ? network.capabilities.subid_param
    : 'subid';

  let prepared;
  try {
    prepared = await prepareClick(coupon.partner_url as string, subIdParam);
  } catch {
    // An insecure or malformed destination. Refuse to track, and do not hand
    // back a downgraded URL either — the catalog has a bad row and a human
    // should see it.
    safeLog({ event: 'affiliate_click_bad_destination', fn: 'prepare-affiliate-click', correlation_id: cid });
    return apiError('invalid_payload', { correlationId: cid });
  }

  const { error } = await supabase.from('affiliate_clicks').insert({
    click_id: prepared.clickId,
    coupon_id: couponId,
    offer_source_id: source?.id ?? null,
    network_key: network.network_key,
    claim_secret_hash: prepared.claimSecretHash,
    surface: readString(body, 'surface') ?? 'unknown',
  });
  if (error) {
    safeLog({ event: 'affiliate_click_insert_failed', fn: 'prepare-affiliate-click', correlation_id: cid });
    // Fall back to untracked rather than failing the user's tap. They still
    // reach the offer; we just do not earn on it.
    return json({ tracked: false, url: coupon.partner_url });
  }

  safeLog({
    event: 'affiliate_click_prepared',
    fn: 'prepare-affiliate-click',
    correlation_id: cid,
    // NO click id, NO owner key. A log line that pairs an identity with a click
    // would rebuild exactly the link the schema refuses to store.
    latency_bucket: latencyBucket(Date.now() - startedAt),
  });

  return json({
    tracked: true,
    url: prepared.trackingUrl,
    click_id: prepared.clickId,
    // Returned ONCE. The device is the only place this will ever exist.
    claim_token: prepared.claimToken,
  });
});
