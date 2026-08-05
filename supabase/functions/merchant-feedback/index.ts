// MALI-044 — RETIRED endpoint.
//
// This was a never-implemented no-op: it validated a keyword list and discarded
// it (`TODO: insert into merchant_keywords_pending` was never built), while
// accepting ANONYMOUS POSTs. Its client (MerchantFeedbackClient.flushIfReady)
// is also unwired — no caller drains the queue. Merchant handling is now served
// by the verified-identity `enrich-merchant` endpoint (MALI-060n).
//
// The route is kept only as an explicit RETIRED responder (410) that first
// requires a bearer token, so it is neither an anonymous surface nor a silent
// success that could be mistaken for a working feature. Do not reintroduce
// behavior here — build any future merchant-feedback flow on the verified
// identity + consent contract instead.
import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

serve((req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }
  // No anonymous access — even to the retired stub. (The Supabase gateway
  // verify_jwt also guards this; the explicit check is defence-in-depth.)
  const auth = req.headers.get('authorization') ?? '';
  if (!auth.startsWith('Bearer ')) {
    return json({ error: 'unauthorized' }, 401);
  }
  return json({ error: 'retired', replacement: 'enrich-merchant' }, 410);
});
