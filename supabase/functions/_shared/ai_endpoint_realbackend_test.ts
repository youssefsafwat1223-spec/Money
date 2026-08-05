// MALI-060n — real-backend contract tests for the idempotency RPCs and device
// verification. Credential-gated: SKIPPED (Deno test `ignore`) unless a real
// Supabase URL + service-role key are present, so `deno test` stays green
// offline. Run with SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY set (against a DB
// with migration 0071 applied) to exercise the atomic claim under real Postgres.
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const URL = Deno.env.get('SUPABASE_URL') ?? '';
const KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const HAS_CREDS = URL.length > 0 && KEY.length > 0;

Deno.test({
  name: 'claim_ai_idempotency: claimed → exists → mismatch (live Postgres)',
  ignore: !HAS_CREDS,
  async fn() {
    const supabase = createClient(URL, KEY);
    const owner = `test:${crypto.randomUUID()}`;
    const requestId = crypto.randomUUID();

    const first = await supabase.rpc('claim_ai_idempotency', {
      p_owner_key: owner,
      p_endpoint: 'parse-sms',
      p_request_id: requestId,
      p_payload_hash: 'hash-a',
      p_ttl_seconds: 60,
    });
    assertEquals(first.data?.[0]?.outcome, 'claimed');

    const repeat = await supabase.rpc('claim_ai_idempotency', {
      p_owner_key: owner,
      p_endpoint: 'parse-sms',
      p_request_id: requestId,
      p_payload_hash: 'hash-a',
      p_ttl_seconds: 60,
    });
    assertEquals(repeat.data?.[0]?.outcome, 'exists');

    const changed = await supabase.rpc('claim_ai_idempotency', {
      p_owner_key: owner,
      p_endpoint: 'parse-sms',
      p_request_id: requestId,
      p_payload_hash: 'hash-B-different',
      p_ttl_seconds: 60,
    });
    assertEquals(changed.data?.[0]?.outcome, 'mismatch');

    // Cleanup.
    await supabase.rpc('prune_ai_request_idempotency');
    await supabase.from('ai_request_idempotency').delete().eq('owner_key', owner);
  },
});

Deno.test({
  name: 'concurrent claims resolve to exactly one claimed (live Postgres)',
  ignore: !HAS_CREDS,
  async fn() {
    const supabase = createClient(URL, KEY);
    const owner = `test:${crypto.randomUUID()}`;
    const requestId = crypto.randomUUID();
    const claim = () =>
      supabase.rpc('claim_ai_idempotency', {
        p_owner_key: owner,
        p_endpoint: 'parse-sms',
        p_request_id: requestId,
        p_payload_hash: 'same',
        p_ttl_seconds: 60,
      });
    const results = await Promise.all([claim(), claim(), claim(), claim()]);
    const claimed = results.filter((r) => r.data?.[0]?.outcome === 'claimed').length;
    assertEquals(claimed, 1); // atomic: exactly one winner, no double-pay
    await supabase.from('ai_request_idempotency').delete().eq('owner_key', owner);
  },
});
