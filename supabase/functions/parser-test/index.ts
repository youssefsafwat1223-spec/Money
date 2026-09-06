import { createClient, type SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';
import {
  type GoldenRow,
  type RowResult,
  validateParser,
} from '../_shared/parser_validation.ts';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-app-version',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};



Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }
  if (req.method !== 'POST') {
    return json({ error: 'Method not allowed' }, 405);
  }

  // Authenticate the caller, then authorize against the server-maintained
  // admin_users allowlist. Never trust a client role/header claim.
  const authHeader = req.headers.get('authorization') ?? '';
  if (!authHeader.startsWith('Bearer ')) {
    return json({ error: 'Unauthorized' }, 401);
  }

  try {
    const body = await req.json();
    const parserId: string = body.parser_id;
    if (!parserId) return json({ error: 'parser_id is required' }, 400);

    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    if (!supabaseUrl || !serviceKey) {
      return json({ error: 'Supabase environment is not configured' }, 500);
    }

    const client = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const token = authHeader.slice('Bearer '.length).trim();
    const { data: authData, error: authError } = await client.auth.getUser(token);
    if (authError || !authData.user) return json({ error: 'Unauthorized' }, 401);
    const { data: adminRow, error: adminError } = await client
      .from('admin_users')
      .select('id')
      .eq('id', authData.user.id)
      .maybeSingle();
    if (adminError) return json({ error: 'Authorization unavailable' }, 503);
    if (!adminRow) return json({ error: 'Forbidden' }, 403);

    // Load the parser rule.
    const { data: parsers, error: parserError } = await client
      .from('sms_parsers')
      .select('*')
      .eq('id', parserId)
      .limit(1);
    if (parserError) return json({ error: parserError.message }, 500);
    if (!parsers || parsers.length === 0) {
      return json({ error: 'Parser not found' }, 404);
    }
    const parser = parsers[0];

    // Load golden tests for the same bank.
    const { data: tests, error: testError } = await client
      .from('parser_golden_tests')
      .select('*')
      .eq('bank_id', parser.bank_id);
    if (testError) return json({ error: testError.message }, 500);

    if (!tests || tests.length === 0) {
      return json({
        parser_id: parserId,
        validation_status: 'pending',
        message: 'No golden tests exist for this bank yet. Add tests first.',
        results: [],
      });
    }

    // ── Validate through the shared contract ──────────────────────────────
    //
    // The previous inline loop compared only match/no-match and amount, while
    // recording currency and type it never checked, and it loaded golden rows
    // by bank_id alone — so a salary message for the same bank failed a
    // debit-only rule as a false_negative. See _shared/parser_validation.ts for
    // the full rationale; the logic lives there so it is unit-testable without
    // a database or a deployment.
    const verdict = validateParser(
      {
        id: parser.id as string,
        sender_pattern: parser.sender_pattern as string,
        message_pattern: parser.message_pattern as string,
        transaction_type: parser.transaction_type as string,
        extracted_fields: (parser.extracted_fields ?? {}) as Record<string, unknown>,
      },
      (tests as GoldenRow[]),
    );

    const results = verdict.results;
    const status = verdict.status;

    // golden_test_count records rows that carried real signal, and is 0 on a
    // failed run — `passed` with no evidence is the state 0087 exists to stop.
    await updateValidationStatus(
      client,
      parserId,
      status,
      verdict.golden_test_count,
      verdict.false_positive_count,
      verdict.amount_error_count,
      results,
    );

    return json({
      parser_id: parserId,
      validation_status: status,
      failure_reason: verdict.reason ?? null,
      // What the run actually established, not merely how many rows it read.
      golden_test_count: verdict.golden_test_count,
      rows_considered: results.length,
      applicable_positive_count: verdict.applicable_positive_count,
      applicable_negative_count: verdict.applicable_negative_count,
      out_of_scope_count: verdict.out_of_scope_count,
      passed_count: results.filter((r) => r.passed).length,
      failed_count: results.filter((r) => !r.passed).length,
      false_positive_count: verdict.false_positive_count,
      amount_error_count: verdict.amount_error_count,
      results,
    });
  } catch (err) {
    console.error('parser-test failed', err);
    return json({ error: 'Unexpected parser test failure' }, 500);
  }
});

async function updateValidationStatus(
  client: SupabaseClient<any, 'public', 'public', any, any>,
  parserId: string,
  status: string,
  testCount: number,
  falsePositives: number,
  amountErrors: number,
  results: RowResult[],
) {
  await client
    .from('sms_parsers')
    .update({
      validation_status: status,
      golden_test_count: testCount,
      false_positive_count: falsePositives,
      amount_error_count: amountErrors,
      validated_at: new Date().toISOString(),
    })
    .eq('id', parserId);
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}
