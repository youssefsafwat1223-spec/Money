import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

// Google deprecates model IDs fast — gemini-2.0-flash-lite was shut down 2026-06-01.
// Pin to a stable versioned ID, not an alias. Current: gemini-2.5-flash-lite-preview-06-17.
// If switching to gemini-2.5-flash (non-lite), set thinkingBudget: 0 in generationConfig
// to prevent thinking tokens inflating output cost beyond the advertised rate.
// Track cutover dates at: https://ai.google.dev/gemini-api/docs/models/gemini
const GEMINI_MODEL = Deno.env.get('GEMINI_MODEL') ?? 'gemini-2.5-flash-lite';
const GEMINI_API_KEY = Deno.env.get('GEMINI_API_KEY') ?? '';
const GEMINI_URL = `https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent`;
const RATE_LIMIT_PER_DAY = 20;

// Server-side re-sanitization mirrors Dart SmsSanitizer — belt-and-suspenders
// in case the client-side sanitizer is bypassed or has a bug.
function reSanitize(text: string): string {
  text = text.replace(/\b\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4}\b/g, '[CARD]');
  text = text.replace(/\b05\d{8}\b/g, '[PHONE]');
  text = text.replace(/\b01[0125]\d{8}\b/g, '[PHONE]');
  text = text.replace(/\+\d{7,15}\b/g, '[PHONE]');
  text = text.replace(/\b\d{10,20}\b/g, '[ACCOUNT]');
  text = text.replace(/(إلى|الى)\s*:?\s*.+/gi, '$1: [REDACTED]');
  text = text.replace(/\bTo\s*:\s*.+/gi, 'To: [REDACTED]');
  text = text.replace(/(عزيزي|عزيزتي)\s+\S+/gi, '[REDACTED]');
  return text.trim();
}

async function hashInstallId(installId: string): Promise<string> {
  const data = new TextEncoder().encode(installId);
  const hashBuffer = await crypto.subtle.digest('SHA-256', data);
  return Array.from(new Uint8Array(hashBuffer))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join()
    .slice(0, 16);
}

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  // Require Authorization header with Bearer token (anon JWT)
  const authHeader = req.headers.get('Authorization');
  if (!authHeader?.startsWith('Bearer ')) {
    return new Response(JSON.stringify({ error: 'unauthorized' }), {
      status: 401, headers: corsHeaders,
    });
  }

  // Verify the JWT is a valid Supabase token
  const supabase = createClient(
    Deno.env.get('SUPABASE_URL') ?? '',
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
  );
  const jwt = authHeader.slice(7);
  const { error: authError } = await supabase.auth.getUser(jwt);
  if (authError) {
    return new Response(JSON.stringify({ error: 'unauthorized' }), {
      status: 401, headers: corsHeaders,
    });
  }

  const body = await req.json().catch(() => null);
  if (!body?.sanitized_sms || !body?.install_id) {
    return new Response(JSON.stringify({ error: 'missing_fields' }), {
      status: 400, headers: corsHeaders,
    });
  }

  const installIdHash = await hashInstallId(body.install_id as string);
  const today = new Date().toISOString().slice(0, 10);

  // Rate-limit check: 20 calls per install_id hash per day
  const { data: rateRow } = await supabase
    .from('ai_rate_limits')
    .select('call_count')
    .eq('install_id_hash', installIdHash)
    .eq('date', today)
    .maybeSingle();

  const currentCount = (rateRow?.call_count ?? 0) as number;
  if (currentCount >= RATE_LIMIT_PER_DAY) {
    return new Response(JSON.stringify({ error: 'rate_limit_exceeded' }), {
      status: 429, headers: corsHeaders,
    });
  }

  await supabase.from('ai_rate_limits').upsert(
    { install_id_hash: installIdHash, date: today, call_count: currentCount + 1 },
    { onConflict: 'install_id_hash,date' },
  );

  // Re-sanitize server-side before sending to Gemini
  const reSanitized = reSanitize(body.sanitized_sms as string);

  if (!GEMINI_API_KEY) {
    return new Response(JSON.stringify({ error: 'ai_not_configured' }), {
      status: 503, headers: corsHeaders,
    });
  }

  const prompt = `You are a bank SMS parser. Extract transaction details from this sanitized bank SMS.
Return ONLY a JSON object. Omit fields you cannot determine. Amount MUST appear in the message.

Fields:
- amount: number (required)
- currency: ISO code like "SAR", "EGP", "AED" (required)
- merchant_name: string (business name for payment/POS only — omit for transfers)
- type: "payment" | "withdrawal" | "transfer" | "income" | "refund" | "unknown"
- category_key: "restaurants" | "groceries" | "transport" | "entertainment" | "health" | "utilities" | "shopping" | "subscriptions" | "transfers" | "income" | "cash" | "other"

SMS: ${reSanitized}

Return ONLY valid JSON. No markdown, no explanation.`;

  let parsed: Record<string, unknown> | null = null;
  try {
    const geminiRes = await fetch(`${GEMINI_URL}?key=${GEMINI_API_KEY}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        contents: [{ parts: [{ text: prompt }] }],
        generationConfig: { temperature: 0, maxOutputTokens: 256 },
      }),
    });
    if (!geminiRes.ok) throw new Error(`gemini_${geminiRes.status}`);
    const geminiJson = await geminiRes.json();
    const text: string = geminiJson?.candidates?.[0]?.content?.parts?.[0]?.text ?? '';
    const cleaned = text.replace(/```json\n?/g, '').replace(/```\n?/g, '').trim();
    parsed = JSON.parse(cleaned);
  } catch {
    return new Response(JSON.stringify({ error: 'ai_parse_failed' }), {
      status: 502, headers: corsHeaders,
    });
  }

  if (!parsed || typeof parsed.amount !== 'number' || !parsed.currency) {
    return new Response(JSON.stringify({ error: 'invalid_ai_response' }), {
      status: 502, headers: corsHeaders,
    });
  }

  return new Response(
    JSON.stringify({ ...parsed, model_used: GEMINI_MODEL }),
    { headers: { 'Content-Type': 'application/json', ...corsHeaders } },
  );
});
