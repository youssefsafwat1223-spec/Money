import {
  createClient,
  type SupabaseClient,
} from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-app-version",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

interface GoldenTest {
  id: string;
  sender: string;
  message_text: string;
  expected_type: string;
  expected_amount: number | null;
  expected_currency: string | null;
  is_otp: boolean;
  is_promo: boolean;
}

interface TestResult {
  test_id: string;
  sender: string;
  passed: boolean;
  failure_kind: string | null;
  matched: boolean;
  extracted_amount: number | null;
  extracted_currency: string | null;
  extracted_type: string | null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  // Authenticate the caller, then authorize against the server-maintained
  // admin_users allowlist. Never trust a client role/header claim.
  const authHeader = req.headers.get("authorization") ?? "";
  if (!authHeader.startsWith("Bearer ")) {
    return json({ error: "Unauthorized" }, 401);
  }

  try {
    const body = await req.json();
    const parserId: string = body.parser_id;
    if (!parserId) return json({ error: "parser_id is required" }, 400);

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !serviceKey) {
      return json({ error: "Supabase environment is not configured" }, 500);
    }

    const client = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const token = authHeader.slice("Bearer ".length).trim();
    const { data: authData, error: authError } = await client.auth.getUser(token);
    if (authError || !authData.user) return json({ error: "Unauthorized" }, 401);
    const { data: adminRow, error: adminError } = await client
      .from("admin_users")
      .select("id")
      .eq("id", authData.user.id)
      .maybeSingle();
    if (adminError) return json({ error: "Authorization unavailable" }, 503);
    if (!adminRow) return json({ error: "Forbidden" }, 403);

    // Load the parser rule.
    const { data: parsers, error: parserError } = await client
      .from("sms_parsers")
      .select("*")
      .eq("id", parserId)
      .limit(1);
    if (parserError) return json({ error: parserError.message }, 500);
    if (!parsers || parsers.length === 0) {
      return json({ error: "Parser not found" }, 404);
    }
    const parser = parsers[0];

    // Load golden tests for the same bank.
    const { data: tests, error: testError } = await client
      .from("parser_golden_tests")
      .select("*")
      .eq("bank_id", parser.bank_id);
    if (testError) return json({ error: testError.message }, 500);

    if (!tests || tests.length === 0) {
      return json({
        parser_id: parserId,
        validation_status: "pending",
        message: "No golden tests exist for this bank yet. Add tests first.",
        results: [],
      });
    }

    // Compile regex patterns (JavaScript regex, not Dart — this is server-side validation).
    // Named groups use (?<name>...) which is valid in both Dart and JS.
    let senderRe: RegExp;
    let messageRe: RegExp;
    try {
      senderRe = new RegExp(parser.sender_pattern, "i");
      messageRe = new RegExp(parser.message_pattern, "i");
    } catch (e) {
      await updateValidationStatus(client, parserId, "failed", 0, 0, 0, []);
      return json({
        parser_id: parserId,
        validation_status: "failed",
        failure_reason: `Invalid regex: ${e}`,
        results: [],
      });
    }

    const results: TestResult[] = [];
    let falsePositives = 0;
    let amountErrors = 0;

    for (const test of tests as GoldenTest[]) {
      const senderMatches = senderRe.test(test.sender);
      const msgMatch = senderMatches ? messageRe.exec(test.message_text) : null;
      const matched = senderMatches && msgMatch !== null;

      const result: TestResult = {
        test_id: test.id,
        sender: test.sender,
        passed: false,
        failure_kind: null,
        matched,
        extracted_amount: null,
        extracted_currency: null,
        extracted_type: null,
      };

      // ── Critical: OTP / promo parsed as transaction ──────────────────────
      if ((test.is_otp || test.is_promo) && matched) {
        result.failure_kind = test.is_otp ? "otp_false_positive" : "promo_false_positive";
        falsePositives++;
        results.push(result);
        // Fail immediately on critical false positive — no point continuing.
        await updateValidationStatus(
          client,
          parserId,
          "failed",
          tests.length,
          falsePositives,
          amountErrors,
          results,
        );
        return json({
          parser_id: parserId,
          validation_status: "failed",
          failure_reason: `Critical: ${result.failure_kind} on test ${test.id}`,
          golden_test_count: tests.length,
          false_positive_count: falsePositives,
          amount_error_count: amountErrors,
          results,
        });
      }

      // ── Expected to NOT match (type = 'ignored') ─────────────────────────
      if (test.expected_type === "ignored") {
        if (matched) {
          result.failure_kind = "false_positive";
          falsePositives++;
        } else {
          result.passed = true;
        }
        results.push(result);
        continue;
      }

      // ── Expected to match ─────────────────────────────────────────────────
      if (!matched) {
        result.failure_kind = "false_negative";
        results.push(result);
        continue;
      }

      // Extract fields from named groups.
      const groups = msgMatch.groups ?? {};
      const rawAmount = groups["amount"]?.replace(/,/g, "");
      const extractedAmount = rawAmount !== undefined ? parseFloat(rawAmount) : null;
      const extractedCurrency = groups["currency"] ?? null;
      const extractedType = parser.transaction_type ?? null;

      result.extracted_amount = extractedAmount;
      result.extracted_currency = extractedCurrency;
      result.extracted_type = extractedType;

      // ── Amount accuracy check ─────────────────────────────────────────────
      if (test.expected_amount !== null && extractedAmount !== null) {
        if (Math.abs(extractedAmount - test.expected_amount) > 0.001) {
          result.failure_kind = "amount_mismatch";
          amountErrors++;
          results.push(result);
          continue;
        }
      } else if (test.expected_amount !== null && extractedAmount === null) {
        result.failure_kind = "amount_not_extracted";
        amountErrors++;
        results.push(result);
        continue;
      }

      result.passed = true;
      results.push(result);
    }

    // ── Final verdict ─────────────────────────────────────────────────────────
    const totalFailed = results.filter((r) => !r.passed).length;
    const status = totalFailed === 0 && falsePositives === 0 && amountErrors === 0
      ? "passed"
      : "failed";

    await updateValidationStatus(
      client,
      parserId,
      status,
      tests.length,
      falsePositives,
      amountErrors,
      results,
    );

    return json({
      parser_id: parserId,
      validation_status: status,
      golden_test_count: tests.length,
      passed_count: results.filter((r) => r.passed).length,
      failed_count: totalFailed,
      false_positive_count: falsePositives,
      amount_error_count: amountErrors,
      results,
    });
  } catch (err) {
    console.error("parser-test failed", err);
    return json({ error: "Unexpected parser test failure" }, 500);
  }
});

async function updateValidationStatus(
  client: SupabaseClient<any, "public", "public", any, any>,
  parserId: string,
  status: string,
  testCount: number,
  falsePositives: number,
  amountErrors: number,
  results: TestResult[],
) {
  const failedCount = results.filter((r) => !r.passed).length;
  await client
    .from("sms_parsers")
    .update({
      validation_status: status,
      golden_test_count: testCount,
      false_positive_count: falsePositives,
      amount_error_count: amountErrors,
      validated_at: new Date().toISOString(),
    })
    .eq("id", parserId);
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
