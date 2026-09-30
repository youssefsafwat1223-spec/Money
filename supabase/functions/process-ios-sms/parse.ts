import rules from './parser_rules.json' with { type: 'json' };
import { extractCaptureAmount } from './money.ts';
import {
  type AiCandidate,
  CURRENCY_CODES,
  directionContradictsWording,
  last4Grounded,
  type LocalCandidate,
  merchantGrounded,
  validateAiCandidate,
} from '../_shared/ai_candidate_validator.ts';

export type ParsedCapture = {
  amount?: number;
  amount_text?: string;
  currency?: string;
  type?: string;
  merchant?: string;
  category?: string;
  confidence?: number;
  duplicateStatus?: 'normal' | 'suspicious_duplicate';
  possibleDuplicateOfPayloadId?: string;
  possibleDuplicateOfTransactionId?: string;
  occurredAt?: string;
  last4?: string;
  direction?: string;
  comparisonTimestamp?: string;
  comparisonTimestampSource?: 'sms_body' | 'received_at';
  rawMessage?: string;
  senderId?: string;
  parserSource?: 'deterministic' | 'ai_hybrid';
  serverTransactionId?: string;
};

// Read lazily so tests (and key rotation) see the current environment.
const GEMINI_MODEL = () => Deno.env.get('GEMINI_MODEL') ?? 'gemini-2.5-flash-lite';
const GEMINI_API_KEY = () => Deno.env.get('GEMINI_API_KEY') ?? '';
const geminiUrl = () => `https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL()}:generateContent`;

const AI_CATEGORIES = [
  'restaurants',
  'groceries',
  'transport',
  'fuel',
  'bills',
  'shopping',
  'health',
  'education',
  'entertainment',
  'subscriptions',
  'transfers',
  'cash',
  'travel',
  'gifts',
  'kids',
  'home',
  'cafes',
  'maintenance',
  'fitness',
  'beauty',
  'charity',
  'pets',
  'insurance',
  'income',
  'other',
];
const AI_TYPES = ['payment', 'withdrawal', 'transfer', 'income', 'refund', 'unknown'];

export type ParseOutcome = {
  parsed: ParsedCapture;
  /** Binary product outcome: true => processed-eligible, false => rejected. */
  accepted: boolean;
};

/**
 * RESOLVED: the deterministic parse alone is a complete capture. Field-based
 * definition (NOT a confidence threshold): amount AND currency AND a known
 * direction (debit/credit) AND a merchant. The on-device parser uses its own
 * (0.92) bar; the two are intentionally not claimed to be equivalent.
 */
export function isResolved(p: ParsedCapture): boolean {
  return !!p.amount && p.amount > 0 && !!p.currency &&
    (p.direction === 'debit' || p.direction === 'credit') && !!p.merchant;
}

function isIgnoredText(lower: string): boolean {
  return (rules.ignoreKeywords as string[]).some((keyword) => lower.includes(keyword.toLowerCase()));
}

/**
 * Binary capture parse. AI confidence never decides anything:
 *  - ignored            -> no AI call, rejected
 *  - RESOLVED           -> no AI call, accepted (deterministic)
 *  - unresolved, no AI  -> no AI call, rejected
 *  - unresolved + AI    -> exactly one AI call, deterministic validator, then
 *                          accepted (AI may only FILL missing fields) or rejected
 */
export async function parseSms(input: {
  text: string;
  rawText: string;
  sender: string;
  receivedAt: string;
  tzOffsetMinutes: number | null;
  locale: string;
  allowAi: boolean;
}): Promise<ParseOutcome> {
  const deterministic = deterministicParse(input.text, input.receivedAt, input.tzOffsetMinutes);
  const fallback: ParsedCapture = {
    ...deterministic,
    rawMessage: input.rawText,
    senderId: input.sender || undefined,
    parserSource: 'deterministic',
  };
  if (isIgnoredText(normalize(input.text).toLowerCase())) return { parsed: fallback, accepted: false };
  if (isResolved(deterministic)) return { parsed: fallback, accepted: true };
  if (!input.allowAi) return { parsed: fallback, accepted: false };

  const ai = await aiParse(input.text);
  if (!ai) return { parsed: fallback, accepted: false };

  // HYBRID when the deterministic parse already had amount+currency, else AI-only.
  const hasLocalMoney = !!deterministic.amount && deterministic.amount > 0 && !!deterministic.currency;
  const local: LocalCandidate | null = hasLocalMoney
    ? {
      amount: deterministic.amount!,
      amount_text: deterministic.amount_text,
      currency: deterministic.currency!,
      direction: deterministic.direction,
      merchant: deterministic.merchant,
    }
    : null;
  const validation = validateAiCandidate({
    candidate: ai,
    sanitizedText: input.text,
    receivedAt: input.receivedAt,
    local,
  });
  if (!validation.accepted) return { parsed: fallback, accepted: false };

  // Fill-only merge: a deterministic value is never overridden.
  const amount = hasLocalMoney ? deterministic.amount! : Number(validation.amountText);
  const amount_text = hasLocalMoney ? deterministic.amount_text : validation.amountText;
  const currency = validation.currency;

  const merchant = deterministic.merchant ??
    (merchantGrounded(validation.merchant, input.text) ? validation.merchant! : undefined);
  const last4 = deterministic.last4 ?? (last4Grounded(ai.last4, input.text) ? ai.last4 : undefined);

  const detKnown = deterministic.direction === 'debit' || deterministic.direction === 'credit';
  let direction = deterministic.direction;
  let type = deterministic.type;
  if (!detKnown) {
    const aiDir = ai.direction === 'credit' || ai.direction === 'debit' ? ai.direction : undefined;
    const aiType = AI_TYPES.includes(ai.type ?? '') ? ai.type : undefined;
    const typeDir = aiType === 'income' || aiType === 'refund'
      ? 'credit'
      : aiType === 'payment' || aiType === 'withdrawal'
      ? 'debit'
      : undefined;
    const filled = aiDir ?? typeDir;
    // Already checked by the validator; re-asserted so a fill can never contradict.
    if (filled && !directionContradictsWording(input.text, aiType, filled)) {
      direction = filled;
      type = aiType && aiType !== 'unknown' ? aiType : filled === 'credit' ? 'income' : 'payment';
    } else if (aiType === 'transfer') {
      type = 'transfer';
    }
  }

  // Category is enrichment: only the catch-all/missing deterministic value yields.
  const aiCategory = AI_CATEGORIES.includes(ai.category ?? '') ? ai.category : undefined;
  const category = deterministic.category && deterministic.category !== 'other'
    ? deterministic.category
    : (aiCategory ?? deterministic.category);

  const aiTimestamp = validation.occurredAt
    ? trustedSmsTimestamp(validation.occurredAt, input.receivedAt, input.tzOffsetMinutes)
    : undefined;
  const deterministicTimestamp = deterministic.comparisonTimestampSource === 'sms_body'
    ? trustedSmsTimestamp(deterministic.comparisonTimestamp, input.receivedAt, input.tzOffsetMinutes)
    : undefined;
  const comparisonTimestamp = deterministicTimestamp ?? aiTimestamp ?? input.receivedAt;

  // Deterministic formula over the FINAL fields. Informational only: it never
  // feeds status. An AI-filled direction does not count.
  const confidence = 0.55 + (detKnown ? 0.15 : 0) + (merchant ? 0.1 : 0) + (last4 ? 0.05 : 0);

  return {
    accepted: true,
    parsed: {
      amount,
      ...(amount_text == null ? {} : { amount_text }),
      currency,
      type,
      merchant,
      category,
      last4,
      direction,
      confidence,
      rawMessage: input.rawText,
      senderId: input.sender || undefined,
      occurredAt: comparisonTimestamp,
      comparisonTimestamp,
      comparisonTimestampSource: deterministicTimestamp || aiTimestamp ? 'sms_body' : 'received_at',
      parserSource: 'ai_hybrid',
    },
  };
}

export function deterministicParse(
  text: string,
  receivedAt: string,
  tzOffsetMinutes: number | null,
): ParsedCapture {
  const normalized = normalize(text);
  const lower = normalized.toLowerCase();
  if (isIgnoredText(lower)) {
    return { confidence: 0, comparisonTimestamp: receivedAt, comparisonTimestampSource: 'received_at' };
  }

  const currency = extractCurrency(normalized);
  const amountFields = extractCaptureAmount(normalized, rules.amountPatterns as string[], currency);
  const amount = amountFields.amount;
  const merchant = extractMerchant(normalized);
  const last4 = extractFirstGroup(normalized, rules.last4Patterns as string[]);
  const direction = detectDirection(lower);
  const type = direction === 'credit' ? 'income' : direction === 'debit' ? 'payment' : 'unknown';
  const category = type === 'income' ? 'income' : inferCategory(merchant, type);
  const occurredAt = trustedSmsTimestamp(
    extractTimestamp(normalized, receivedAt, tzOffsetMinutes),
    receivedAt,
    tzOffsetMinutes,
  );
  const confidence = (amount && currency ? 0.55 : 0) +
    (direction !== 'unknown' ? 0.15 : 0) +
    (merchant ? 0.1 : 0) +
    (last4 ? 0.05 : 0);
  return {
    ...amountFields,
    currency,
    merchant,
    last4,
    direction,
    type,
    category,
    confidence,
    occurredAt: occurredAt ?? receivedAt,
    comparisonTimestamp: occurredAt ?? receivedAt,
    comparisonTimestampSource: occurredAt ? 'sms_body' : 'received_at',
  };
}

async function aiParse(text: string): Promise<AiCandidate | null> {
  const apiKey = GEMINI_API_KEY();
  if (!apiKey) return null;
  const prompt = `Extract one bank transaction from this sanitized SMS.
Return only JSON. If not a transaction return {"is_transaction":false}.
Fields: amount number (required legacy compatibility value), amount_text string (required exact plain-decimal token
from the SMS, no exponent or rounding), currency ISO, merchant string, type payment|withdrawal|transfer|income|refund|unknown, direction credit|debit|unknown, category restaurants|groceries|transport|fuel|bills|shopping|health|education|entertainment|subscriptions|transfers|cash|travel|gifts|kids|home|cafes|maintenance|fitness|beauty|charity|pets|insurance|income|other, occurredAt ISO if present, last4 if present.
Example money shape: {"amount":19.99,"amount_text":"19.99","currency":"EGP"}.
IPN/InstaPay/person-to-person transfers (SMS contains "IPN REF", "IPN transfer", "Instapay", "credited by ... from <person>", "received from <person>", or "sent to <person>") are type=transfer, category=transfers, and merchant must be omitted even if a person's name appears — never type=income, never a merchant name. direction=credit for incoming/received, debit for sent/outgoing.
SMS: ${text}`;
  try {
    // Bounded: an unbounded Gemini call pushes the whole request past the App
    // Intent's 8s timeout, and the intent then posts a local fallback banner
    // while this function still commits + sends APNs (duplicate notification).
    const response = await fetch(geminiUrl(), {
      signal: AbortSignal.timeout(3500),
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-goog-api-key': apiKey,
      },
      body: JSON.stringify({
        contents: [{ parts: [{ text: prompt }] }],
        generationConfig: {
          temperature: 0.1,
          maxOutputTokens: 512,
          responseMimeType: 'application/json',
        },
      }),
    });
    if (!response.ok) return null;
    const data = await response.json();
    const raw = data?.candidates?.[0]?.content?.parts?.[0]?.text;
    if (typeof raw !== 'string') return null;
    const parsed = JSON.parse(raw);
    if (parsed?.is_transaction === false) return null;
    if (!parsed || typeof parsed !== 'object') return null;
    // Raw model fields only: the exact-text / grounding checks live in the
    // validator (amount_text is NOT pre-sanitised here, so its rejection reason
    // stays visible). Model confidence is deliberately not read.
    return {
      amount: typeof parsed.amount === 'number' ? parsed.amount : undefined,
      amount_text: typeof parsed.amount_text === 'string' ? parsed.amount_text : undefined,
      currency: typeof parsed.currency === 'string' ? parsed.currency.toUpperCase() : undefined,
      merchant: typeof parsed.merchant === 'string' ? parsed.merchant : undefined,
      type: typeof parsed.type === 'string' ? parsed.type : undefined,
      direction: typeof parsed.direction === 'string' ? parsed.direction : undefined,
      category: typeof parsed.category === 'string' ? parsed.category : undefined,
      occurred_at: typeof parsed.occurredAt === 'string' ? parsed.occurredAt : undefined,
      last4: typeof parsed.last4 === 'string' ? parsed.last4 : undefined,
    };
  } catch (_) {
    return null;
  }
}

function normalize(input: string): string {
  let text = normalizeDigits(input);
  for (const mark of rules.normalization.decimalMarks as string[]) text = text.replaceAll(mark, '.');
  for (const mark of rules.normalization.thousandsMarks as string[]) text = text.replaceAll(mark, ',');
  for (const rule of rules.normalization.currencyReplacements as Array<{ pattern: string; replacement: string }>) {
    text = text.replace(new RegExp(rule.pattern, 'gi'), rule.replacement);
  }
  return text;
}

function normalizeDigits(input: string): string {
  return Array.from(input).map((char) => {
    const code = char.charCodeAt(0);
    if (code >= 0x0660 && code <= 0x0669) return String(code - 0x0660);
    if (code >= 0x06F0 && code <= 0x06F9) return String(code - 0x06F0);
    return char;
  }).join('');
}

function extractCurrency(text: string): string | undefined {
  const match = new RegExp(rules.currencyPattern as string, 'i').exec(text);
  return normalizeCurrencyCode(match?.[1]);
}

function normalizeCurrencyCode(value?: string): string | undefined {
  if (typeof value !== 'string') return undefined;
  const normalized = value.trim().toUpperCase();
  return CURRENCY_CODES.includes(normalized) ? normalized : undefined;
}

function extractMerchant(text: string): string | undefined {
  const raw = extractFirstGroup(text, rules.merchantPatterns as string[]);
  if (!raw) return undefined;
  const stop = new RegExp(rules.merchantStopPattern as string, 'i');
  const merchant = raw
    .replace(stop, '')
    .replace(/^[\s.,:;؛*\-]+/g, '')
    .replace(/[\s.,:;؛*\-]+$/g, '')
    .trim();
  return merchant || undefined;
}

function extractFirstGroup(text: string, patterns: string[]): string | undefined {
  for (const pattern of patterns) {
    const match = new RegExp(pattern, 'i').exec(text);
    const value = match?.[1]?.trim();
    if (value) return value;
  }
  return undefined;
}

function detectDirection(lower: string): 'credit' | 'debit' | 'unknown' {
  const debit = earliest(lower, rules.debitKeywords as string[]);
  const credit = earliest(lower, rules.creditKeywords as string[]);
  if (debit == null && credit == null) return 'unknown';
  if (credit == null) return 'debit';
  if (debit == null) return 'credit';
  return debit <= credit ? 'debit' : 'credit';
}

function earliest(lower: string, keywords: string[]): number | null {
  let result: number | null = null;
  for (const keyword of keywords) {
    const index = lower.indexOf(keyword.toLowerCase());
    if (index >= 0 && (result == null || index < result)) result = index;
  }
  return result;
}

function inferCategory(merchant: string | undefined, type: string): string {
  if (type === 'income') return 'income';
  if (type === 'withdrawal') return 'cash';
  const value = (merchant ?? '').toUpperCase();
  const rulesByMerchant: Array<[string, string]> = [
    ['STARBUCKS', 'cafes'],
    ['COSTA', 'cafes'],
    ['CARREFOUR', 'groceries'],
    ['KAZION', 'groceries'],
    ['NOON', 'shopping'],
    ['AMAZON', 'shopping'],
    ['UBER', 'transport'],
    ['CAREEM', 'transport'],
    ['VODAFONE', 'bills'],
    ['STC', 'bills'],
    ['ADNOC', 'fuel'],
    ['SHELL', 'fuel'],
    ['NETFLIX', 'subscriptions'],
  ];
  for (const [needle, category] of rulesByMerchant) {
    if (value.includes(needle)) return category;
  }
  return 'other';
}

function extractTimestamp(
  text: string,
  receivedAt: string,
  tzOffsetMinutes: number | null,
): string | undefined {
  const reference = localReference(receivedAt, tzOffsetMinutes);
  const iso = /(\d{4})[-/](\d{1,2})[-/](\d{1,2})(?:[ T]+(\d{1,2}):(\d{2}))?/i.exec(text);
  if (iso) {
    return makeTimestamp(
      Number(iso[1]),
      Number(iso[2]),
      Number(iso[3]),
      Number(iso[4] ?? 12),
      Number(iso[5] ?? 0),
      tzOffsetMinutes,
    );
  }
  const dmy = /(\d{1,2})[-/](\d{1,2})(?:[-/](\d{2,4}))?(?:(?:\s*(?:t|at|الساعة)\s*)(\d{1,2}):(\d{2}))?/i.exec(text);
  if (dmy) {
    const year = dmy[3] ? normalizeYear(Number(dmy[3])) : reference.year;
    return makeTimestamp(
      year,
      Number(dmy[2]),
      Number(dmy[1]),
      Number(dmy[4] ?? 12),
      Number(dmy[5] ?? 0),
      tzOffsetMinutes,
    );
  }
  const time = /(?:الساعة|at)\s*(\d{1,2}):(\d{2})/i.exec(text);
  if (time) {
    return makeTimestamp(
      reference.year,
      reference.month,
      reference.day,
      Number(time[1]),
      Number(time[2]),
      tzOffsetMinutes,
    );
  }
  return undefined;
}

const MAX_SMS_TIMESTAMP_PAST_MS = 31 * 24 * 60 * 60 * 1000;
const MAX_SMS_TIMESTAMP_FUTURE_MS = 24 * 60 * 60 * 1000;

function trustedSmsTimestamp(
  candidate: string | undefined,
  receivedAt: string,
  tzOffsetMinutes: number | null,
): string | undefined {
  if (!candidate) return undefined;
  const timestamp = parseTimestamp(candidate, tzOffsetMinutes);
  const reference = parseTimestamp(receivedAt);
  if (!timestamp || !reference) return undefined;

  const delta = timestamp.getTime() - reference.getTime();
  if (delta < -MAX_SMS_TIMESTAMP_PAST_MS || delta > MAX_SMS_TIMESTAMP_FUTURE_MS) {
    return undefined;
  }
  return timestamp.toISOString();
}

function parseTimestamp(
  value: string | undefined,
  tzOffsetMinutes?: number | null,
): Date | null {
  if (!value) return null;
  const clean = value.trim();
  if (!clean) return null;
  const hasZone = /(?:z|[+-]\d{2}:?\d{2})$/i.test(clean);
  if (!hasZone && tzOffsetMinutes != null) {
    const local = /^(\d{4})[-/](\d{1,2})[-/](\d{1,2})(?:[T ]+(\d{1,2}):(\d{2})(?::(\d{2}))?)?$/i.exec(clean);
    if (local) {
      return new Date(localTimestampMs(
        Number(local[1]),
        Number(local[2]),
        Number(local[3]),
        Number(local[4] ?? 12),
        Number(local[5] ?? 0),
        Number(local[6] ?? 0),
        tzOffsetMinutes,
      ));
    }
  }
  const withZone = hasZone ? clean : `${clean}Z`;
  const date = new Date(withZone);
  return Number.isNaN(date.getTime()) ? null : date;
}

function normalizeYear(year: number): number {
  return year < 100 ? 2000 + year : year;
}

function localReference(
  receivedAt: string,
  tzOffsetMinutes: number | null,
): { year: number; month: number; day: number } {
  const reference = parseTimestamp(receivedAt) ?? new Date();
  const local = tzOffsetMinutes == null ? reference : new Date(reference.getTime() + tzOffsetMinutes * 60_000);
  return {
    year: local.getUTCFullYear(),
    month: local.getUTCMonth() + 1,
    day: local.getUTCDate(),
  };
}

function makeTimestamp(
  year: number,
  month: number,
  day: number,
  hour: number,
  minute: number,
  tzOffsetMinutes: number | null,
): string {
  return new Date(localTimestampMs(
    year,
    month,
    day,
    hour,
    minute,
    0,
    tzOffsetMinutes,
  )).toISOString();
}

function localTimestampMs(
  year: number,
  month: number,
  day: number,
  hour: number,
  minute: number,
  second: number,
  tzOffsetMinutes: number | null,
): number {
  const base = Date.UTC(year, month - 1, day, hour, minute, second);
  return tzOffsetMinutes == null ? base : base - tzOffsetMinutes * 60_000;
}
