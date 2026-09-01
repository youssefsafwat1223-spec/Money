// COUPONS Phase 3 — what happened to a click.
//
// The device presents the plaintext claim token it kept when the click was
// minted; the server hashes it, compares in constant time, and answers with one
// of four words.
//
// ═══════════════════════════════════════════════════════════════════════════
// A WRONG TOKEN LEARNS NOTHING. NOT EVEN WHETHER THE CLICK EXISTS.
// ═══════════════════════════════════════════════════════════════════════════
//
// `unknown` covers all of: no such click, expired click, and wrong token. A
// caller cannot tell them apart, so probing click ids reveals nothing — not
// their existence, not their age, not how close a guess was. Any more helpful
// answer would turn this into an oracle for enumerating other people's clicks,
// which is precisely what the anonymous click table exists to prevent.
//
// ## Commission is never in the response
//
// The device is told `pending` / `confirmed` / `declined`. What the network pays
// US for that conversion stays server-side: it is our rate card, it is not the
// user's money, and putting it in a client response would both leak commercial
// terms and invite the app to conflate revenue with the user's savings.

import { bumpCaptureEndpointRateLimit, corsHeaders, readString, serviceClient } from '../_shared/capture_auth.ts';
import {
  apiError,
  consentError,
  correlationId,
  readJsonBody,
  resolveVerifiedIdentity,
  safeLog,
  schemaError,
} from '../_shared/ai_endpoint.ts';
import { publicStatusFor, sha256Hex } from '../_shared/affiliate/attribution.ts';

const MAX_BODY_BYTES = 4096;
/// Higher than the click limit: a device polls a handful of outstanding clicks,
/// and being throttled out of a status check would strand a savings entry in
/// "pending" forever.
const RATE_LIMIT_PER_DAY = 1000;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...corsHeaders },
  });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  const cid = correlationId();
  const supabase = serviceClient();

  const bodyRes = await readJsonBody(req, MAX_BODY_BYTES);
  if (!bodyRes.ok) return apiError(bodyRes.code, { correlationId: cid });
  const body = bodyRes.body as Record<string, unknown>;

  const schemaProblem = schemaError(body, cid);
  if (schemaProblem) return schemaProblem;

  const identity = await resolveVerifiedIdentity(req, supabase, body, cid);
  if (!identity.ok) return identity.response;

  const consentBad = consentError(identity.identity, 'cloud', cid);
  if (consentBad) return consentBad;

  const limited = await bumpCaptureEndpointRateLimit(
    supabase,
    identity.identity.ownerKey,
    'affiliate-click-status',
    RATE_LIMIT_PER_DAY,
  );
  if (limited) return apiError('rate_limited', { correlationId: cid, retryable: true });

  const clickId = readString(body, 'click_id');
  const claimToken = readString(body, 'claim_token');
  if (!clickId || !claimToken) return apiError('invalid_payload', { correlationId: cid });

  const { data: click } = await supabase
    .from('affiliate_clicks')
    .select('claim_secret_hash, expires_at')
    .eq('click_id', clickId)
    .maybeSingle();

  // Hash the presented token even when the click is missing. Returning early on
  // a miss would make a non-existent click measurably faster to answer than a
  // wrong token, which is the same oracle by a different route.
  const presented = await sha256Hex(claimToken);

  let conversionStatus: string | null = null;
  if (click) {
    const { data: conversion } = await supabase
      .from('affiliate_conversions')
      // Status ONLY. Selecting the commission columns here would put them one
      // careless response-shape change away from the client.
      .select('status')
      .eq('click_id', clickId)
      .order('updated_at', { ascending: false })
      .limit(1)
      .maybeSingle();
    conversionStatus = (conversion?.status as string | undefined) ?? null;
  }

  const status = publicStatusFor(
    click as { claim_secret_hash: string; expires_at: string } | null,
    presented,
    conversionStatus,
  );

  safeLog({
    event: 'affiliate_click_status',
    fn: 'affiliate-click-status',
    correlation_id: cid,
    // The RESULT class only. Logging the click id next to an authenticated
    // request would rebuild the identity-to-click link the schema refuses to
    // store — the one thing this whole design is arranged to prevent.
    result: status,
  });

  return json({ status });
});
