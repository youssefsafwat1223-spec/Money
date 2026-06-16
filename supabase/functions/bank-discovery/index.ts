const GEMINI_MODEL = Deno.env.get("GEMINI_MODEL") ?? "gemini-2.5-flash-lite";
const GEMINI_API_KEY = Deno.env.get("GEMINI_API_KEY") ?? "";
const GEMINI_URL =
  `https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent`;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

interface DiscoveryRequest {
  senderId: string;
  sanitizedSms: string;
  detectedCurrency?: string;
  localeHint?: string;
}

interface DiscoverySuggestion {
  suggestedBankName: string;
  bankKeySuggestion?: string;
  country: string;
  confidence: number;
  reason: string;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }

  const authHeader = req.headers.get("authorization") ?? "";
  if (!authHeader.startsWith("Bearer ")) {
    return json({ error: "unauthorized" }, 401);
  }

  const body = await req.json().catch(() => null);
  const parsedRequest = parseRequest(body);
  if ("error" in parsedRequest) {
    console.warn("bank-discovery rejected request", {
      reason: parsedRequest.error,
    });
    return json({ error: parsedRequest.error }, 400);
  }

  const request = parsedRequest.request;
  const safeSms = reSanitize(request.sanitizedSms);
  if (containsUnsafeRawData(safeSms)) {
    console.warn("bank-discovery rejected request", {
      reason: "unsafe_payload",
      senderHash: await shortHash(request.senderId),
      textLength: safeSms.length,
    });
    return json({ error: "unsafe_payload" }, 400);
  }

  const senderHash = await shortHash(request.senderId);
  console.log("bank-discovery request received", {
    senderHash,
    textLength: safeSms.length,
    detectedCurrency: request.detectedCurrency ?? null,
    localeHint: request.localeHint ?? null,
  });

  if (!GEMINI_API_KEY) {
    console.error("bank-discovery Gemini not configured", { senderHash });
    return json({ error: "ai_not_configured" }, 503);
  }

  try {
    const geminiRes = await fetch(`${GEMINI_URL}?key=${GEMINI_API_KEY}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        contents: [{ parts: [{ text: buildPrompt(request, safeSms) }] }],
        generationConfig: {
          temperature: 0,
          maxOutputTokens: 256,
          responseMimeType: "application/json",
        },
      }),
    });
    console.log("bank-discovery Gemini response", {
      senderHash,
      status: geminiRes.status,
      ok: geminiRes.ok,
      model: GEMINI_MODEL,
    });

    if (!geminiRes.ok) {
      return json({ error: "ai_request_failed" }, 200);
    }

    const geminiJson = await geminiRes.json();
    const text: string =
      geminiJson?.candidates?.[0]?.content?.parts?.[0]?.text ?? "";
    const suggestion = parseSuggestion(text);
    if (!suggestion) {
      return json({ error: "no_suggestion" }, 200);
    }

    console.log("bank-discovery suggestion parsed", {
      senderHash,
      country: suggestion.country,
      confidence: suggestion.confidence,
      hasBankKeySuggestion: Boolean(suggestion.bankKeySuggestion),
    });

    return json(suggestion);
  } catch (error) {
    console.error("bank-discovery failed", {
      senderHash,
      error: error instanceof Error ? error.message : "unknown_error",
    });
    return json({ error: "ai_discovery_failed" }, 200);
  }
});

function parseRequest(body: unknown):
  | { request: DiscoveryRequest }
  | { error: string } {
  if (!body || typeof body !== "object") return { error: "invalid_json" };
  const data = body as Record<string, unknown>;
  const senderId = readString(data, "senderId", "sender_id");
  const sanitizedSms = readString(data, "sanitizedSms", "sanitized_sms");
  const detectedCurrency = readOptionalString(
    data,
    "detectedCurrency",
    "detected_currency",
  );
  const localeHint = readOptionalString(data, "localeHint", "locale_hint");

  if (!senderId || !sanitizedSms) return { error: "missing_fields" };
  if (senderId.length > 64) return { error: "sender_too_long" };
  if (sanitizedSms.length > 1200) return { error: "sms_too_long" };

  return {
    request: {
      senderId,
      sanitizedSms,
      detectedCurrency,
      localeHint,
    },
  };
}

function readString(data: Record<string, unknown>, ...keys: string[]): string {
  for (const key of keys) {
    const value = data[key];
    if (typeof value === "string" && value.trim().length > 0) {
      return value.trim();
    }
  }
  return "";
}

function readOptionalString(
  data: Record<string, unknown>,
  ...keys: string[]
): string | undefined {
  const value = readString(data, ...keys);
  return value.length > 0 ? value : undefined;
}

function buildPrompt(request: DiscoveryRequest, safeSms: string): string {
  return `You identify the likely bank behind a sanitized SMS sender.

Task:
- Identify bank identity only.
- Do NOT parse transactions.
- Do NOT return amounts, balances, card numbers, account numbers, or merchant names.
- If the bank is unclear, return confidence below 0.95.

Return ONLY this JSON shape:
{
  "suggestedBankName": "Full official/common bank name",
  "bankKeySuggestion": "lower_snake_key_with_country_suffix",
  "country": "ISO-3166 alpha-2 country code",
  "confidence": 0.0,
  "reason": "Short reason based on sender and wording, no SMS content quote"
}

Sender ID: ${request.senderId}
Detected currency: ${request.detectedCurrency ?? "unknown"}
Locale hint: ${request.localeHint ?? "unknown"}
Sanitized SMS:
${safeSms}`;
}

function parseSuggestion(rawText: string): DiscoverySuggestion | null {
  const cleaned = rawText
    .replace(/```json\n?/gi, "")
    .replace(/```\n?/g, "")
    .trim();
  if (!cleaned) return null;

  let parsed: Record<string, unknown>;
  try {
    parsed = JSON.parse(cleaned);
  } catch {
    return null;
  }

  const suggestedBankName = readString(
    parsed,
    "suggestedBankName",
    "bankName",
    "bank_name",
  );
  const country = readString(parsed, "country").toUpperCase();
  const reason = readString(parsed, "reason");
  const bankKeySuggestion = normalizeBankKey(
    readOptionalString(parsed, "bankKeySuggestion", "bank_key_suggestion"),
    country,
  );
  const rawConfidence = parsed.confidence;
  const confidence = typeof rawConfidence === "number"
    ? Math.max(0, Math.min(1, rawConfidence))
    : Number.NaN;

  if (!suggestedBankName || !country || !reason || !Number.isFinite(confidence)) {
    return null;
  }
  if (!/^[A-Z]{2}$/.test(country)) return null;

  return {
    suggestedBankName: suggestedBankName.slice(0, 120),
    bankKeySuggestion,
    country,
    confidence,
    reason: reason.slice(0, 240),
  };
}

function normalizeBankKey(
  rawKey: string | undefined,
  country: string,
): string | undefined {
  if (!rawKey) return undefined;
  const key = rawKey
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "");
  if (!key) return undefined;
  const countrySuffix = country.toLowerCase();
  return key.endsWith(`_${countrySuffix}`) ? key : `${key}_${countrySuffix}`;
}

function reSanitize(text: string): string {
  return text
    .replace(/\b\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4}\b/g, "[CARD]")
    .replace(/\b05\d{8}\b/g, "[PHONE]")
    .replace(/\b01[0125]\d{8}\b/g, "[PHONE]")
    .replace(/\+\d{7,15}\b/g, "[PHONE]")
    .replace(/\b\d{10,20}\b/g, "[ACCOUNT]")
    .replace(/(A\/C\s*NO\s*:?\s*)\*?\d{4,}/gi, "$1[ACCOUNT]")
    .replace(/(account|acct|a\/c)\s*:?\s*\*?\d{4,}/gi, "$1 [ACCOUNT]")
    .trim();
}

function containsUnsafeRawData(text: string): boolean {
  return [
    /\b\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4}\b/,
    /\b\d{10,20}\b/,
    /\+\d{7,15}\b/,
    /\b05\d{8}\b/,
    /\b01[0125]\d{8}\b/,
  ].some((pattern) => pattern.test(text));
}

async function shortHash(value: string): Promise<string> {
  const data = new TextEncoder().encode(value);
  const hash = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(hash))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("")
    .slice(0, 12);
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json",
    },
  });
}
