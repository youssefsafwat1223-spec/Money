import rules from './parser_rules.json' with { type: 'json' };
import {
  corsHeaders,
  json,
  readString,
  serviceClient,
  sha256Hex,
  verifyDevice,
} from '../_shared/capture_auth.ts';
import { sendCapturePush } from '../_shared/apns.ts';
import { isLedgerDualWriteEnabled, upsertLedgerTransaction } from '../_shared/ledger.ts';

type CaptureStatus = 'processed' | 'needs_review' | 'duplicate' | 'rejected';
type ParsedCapture = {
  amount?: number;
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
};

type NotificationPayload = {
  title: string;
  body: string;
  type: 'new_transaction' | 'needs_review' | 'suspicious_duplicate' | 'received';
};

const CAPTURE_RATE_LIMIT_PER_DAY = 300;
const CURRENCY_CODES = ['SAR', 'AED', 'EGP', 'QAR', 'OMR', 'KWD', 'BHD', 'JOD', 'USD', 'EUR', 'GBP'];
const GEMINI_MODEL = Deno.env.get('GEMINI_MODEL') ?? 'gemini-2.5-flash-lite';
const GEMINI_API_KEY = Deno.env.get('GEMINI_API_KEY') ?? '';
const GEMINI_URL = `https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent`;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);

  const body = await req.json().catch(() => null) as Record<string, unknown> | null;
  if (!body) return json({ error: 'invalid_json' }, 400);

  const installId = readString(body, 'installId', 'install_id');
  const deviceSecret = readString(body, 'deviceSecret', 'device_secret');
  const payloadId = readString(body, 'payloadId', 'payload_id');
  const sanitizedText = reSanitize(readString(body, 'sanitizedText', 'sanitized_text', 'smsText', 'sms_text'));
  const rawText = readString(body, 'smsText', 'sms_text') || sanitizedText;
  const sender = readString(body, 'sender', 'senderId', 'sender_id', 'senderName', 'sender_name');
  const receivedAt = readString(body, 'receivedAt', 'received_at') || new Date().toISOString();
  const locale = readString(body, 'locale', 'deviceLocale', 'device_locale');
  const allowAi = body.allowAi === true || body.allow_ai === true;

  if (!payloadId || !sanitizedText) {
    return json({ error: 'missing_fields' }, 400);
  }

  const supabase = serviceClient();
  const auth = await verifyDevice(supabase, installId, deviceSecret);
  if (!auth.ok) return json({ error: auth.error }, auth.status);

  const existing = await supabase
    .from('processed_captures')
    .select('payload_id,status,parsed,notification,created_at,apns_push_sent_at')
    .eq('payload_id', payloadId)
    .eq('install_id_hash', auth.installIdHash)
    .maybeSingle();
  if (existing.data) {
    return json({
      capture: existing.data,
      idempotent: true,
      pushSent: Boolean(existing.data.apns_push_sent_at),
    });
  }

  const limited = await bumpRateLimit(supabase, auth.installIdHash);
  if (limited) return json({ error: 'rate_limit_exceeded' }, 429);

  const parsed = await parseSms({
    text: sanitizedText,
    rawText,
    sender,
    receivedAt,
    locale,
    allowAi,
  });

  const rawFingerprint = await sha256Hex(`${auth.installIdHash}|${payloadId}|${sanitizedText}`);
  let status: CaptureStatus = parsed.amount && parsed.currency ? 'processed' : 'rejected';
  if (status === 'processed' && ((parsed.confidence ?? 0) < 0.72 || !parsed.category)) {
    status = 'needs_review';
  }

  if (status !== 'rejected') {
    const duplicate = await detectDuplicate(supabase, auth.installIdHash, payloadId, parsed);
    if (duplicate) {
      status = 'duplicate';
      parsed.duplicateStatus = 'suspicious_duplicate';
      parsed.possibleDuplicateOfPayloadId = duplicate;
    } else {
      parsed.duplicateStatus = 'normal';
    }
  }

  const notification = buildNotification(status, parsed, sender);
  const { data, error } = await supabase
    .from('processed_captures')
    .insert({
      payload_id: payloadId,
      install_id_hash: auth.installIdHash,
      status,
      parsed,
      notification,
      sanitized_text: status === 'needs_review' || status === 'rejected' ? sanitizedText : null,
      raw_fingerprint: rawFingerprint,
      failure_reason: status === 'rejected' ? 'not_parseable' : null,
    })
    .select('payload_id,status,parsed,notification,created_at,apns_push_sent_at')
    .single();

  if (error) return json({ error: 'store_failed' }, 500);

  // Phase B: dual-write to user_transactions for signed-in users when flag is on.
  // Guests (userId = null) always stay relay-only.
  // 'rejected' and 'duplicate' are excluded: no meaningful ledger row to write.
  if (auth.userId && (status === 'processed' || status === 'needs_review')) {
    try {
      const dualWriteEnabled = await isLedgerDualWriteEnabled(supabase, auth.userId);
      if (dualWriteEnabled) {
        await upsertLedgerTransaction(supabase, auth.userId, {
          payloadId,
          amount: parsed.amount!,
          currency: parsed.currency!,
          direction: parsed.direction,
          type: parsed.type,
          merchant: parsed.merchant,
          categoryId: parsed.category,
          occurredAt: parsed.occurredAt ?? receivedAt,
          confidence: parsed.confidence,
          last4: parsed.last4,
        });
      }
    } catch (err) {
      // Non-fatal: relay is source of truth in Phase B. Log and continue.
      console.warn(JSON.stringify({ event: 'ledger_dual_write_failed', payloadId, err: String(err) }));
    }
  }

  const pushSent = await sendApnsIfPossible(
    supabase,
    auth.installIdHash,
    payloadId,
    notification,
    parsed,
  );
  return json({
    capture: {
      ...data,
      apns_push_sent_at: pushSent ? new Date().toISOString() : data.apns_push_sent_at,
    },
    pushSent,
  });
});

async function bumpRateLimit(
  supabase: ReturnType<typeof serviceClient>,
  installIdHash: string,
): Promise<boolean> {
  const today = new Date().toISOString().slice(0, 10);
  const { data } = await supabase
    .from('capture_rate_limits')
    .select('call_count')
    .eq('install_id_hash', installIdHash)
    .eq('date', today)
    .maybeSingle();
  const current = (data?.call_count ?? 0) as number;
  if (current >= CAPTURE_RATE_LIMIT_PER_DAY) return true;
  await supabase.from('capture_rate_limits').upsert({
    install_id_hash: installIdHash,
    date: today,
    call_count: current + 1,
  }, { onConflict: 'install_id_hash,date' });
  return false;
}

async function parseSms(input: {
  text: string;
  rawText: string;
  sender: string;
  receivedAt: string;
  locale: string;
  allowAi: boolean;
}): Promise<ParsedCapture> {
  const deterministic = deterministicParse(input.text, input.receivedAt);
  if (deterministic.amount && deterministic.currency && (deterministic.confidence ?? 0) >= 0.78) {
    return {
      ...deterministic,
      rawMessage: input.rawText,
      senderId: input.sender || undefined,
    };
  }
  if (input.allowAi) {
    const ai = await aiParse(input.text);
    if (ai?.amount && ai.currency) {
      return {
        ...deterministic,
        ...ai,
        confidence: Math.max(ai.confidence ?? 0.82, deterministic.confidence ?? 0),
        rawMessage: input.rawText,
        senderId: input.sender || undefined,
        comparisonTimestamp: ai.occurredAt ?? deterministic.comparisonTimestamp ?? input.receivedAt,
        comparisonTimestampSource: ai.occurredAt ? 'sms_body' : (deterministic.comparisonTimestampSource ?? 'received_at'),
      };
    }
  }
  return {
    ...deterministic,
    rawMessage: input.rawText,
    senderId: input.sender || undefined,
  };
}

function deterministicParse(text: string, receivedAt: string): ParsedCapture {
  const normalized = normalize(text);
  const lower = normalized.toLowerCase();
  const ignored = (rules.ignoreKeywords as string[]).some((keyword) => lower.includes(keyword.toLowerCase()));
  if (ignored) return { confidence: 0, comparisonTimestamp: receivedAt, comparisonTimestampSource: 'received_at' };

  const amount = extractNumber(normalized, rules.amountPatterns as string[]);
  const currency = extractCurrency(normalized);
  const merchant = extractMerchant(normalized);
  const last4 = extractFirstGroup(normalized, rules.last4Patterns as string[]);
  const direction = detectDirection(lower);
  const type = direction === 'credit' ? 'income' : direction === 'debit' ? 'payment' : 'unknown';
  const category = type === 'income' ? 'income' : inferCategory(merchant, type);
  const occurredAt = extractTimestamp(normalized);
  const confidence = (amount && currency ? 0.55 : 0) +
    (direction !== 'unknown' ? 0.15 : 0) +
    (merchant ? 0.1 : 0) +
    (last4 ? 0.05 : 0);
  return {
    amount,
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

async function aiParse(text: string): Promise<ParsedCapture | null> {
  if (!GEMINI_API_KEY) return null;
  const prompt = `Extract one bank transaction from this sanitized SMS.
Return only JSON. If not a transaction return {"is_transaction":false}.
Fields: amount number, currency ISO, merchant string, type payment|withdrawal|transfer|income|refund|unknown, direction credit|debit|unknown, category restaurants|groceries|transport|fuel|bills|shopping|health|education|entertainment|subscriptions|transfers|cash|travel|gifts|kids|home|cafes|maintenance|fitness|beauty|charity|pets|insurance|income|other, occurredAt ISO if present, last4 if present.
SMS: ${text}`;
  try {
    const response = await fetch(GEMINI_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-goog-api-key': GEMINI_API_KEY,
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
    return {
      amount: typeof parsed.amount === 'number' ? parsed.amount : undefined,
      currency: typeof parsed.currency === 'string' ? parsed.currency.toUpperCase() : undefined,
      merchant: typeof parsed.merchant === 'string' ? parsed.merchant : undefined,
      type: typeof parsed.type === 'string' ? parsed.type : undefined,
      direction: typeof parsed.direction === 'string' ? parsed.direction : undefined,
      category: typeof parsed.category === 'string' ? parsed.category : undefined,
      occurredAt: typeof parsed.occurredAt === 'string' ? parsed.occurredAt : undefined,
      last4: typeof parsed.last4 === 'string' ? parsed.last4 : undefined,
      confidence: 0.84,
    };
  } catch (_) {
    return null;
  }
}

async function detectDuplicate(
  supabase: ReturnType<typeof serviceClient>,
  installIdHash: string,
  payloadId: string,
  parsed: ParsedCapture,
): Promise<string | null> {
  if (!parsed.amount || !parsed.currency || !parsed.comparisonTimestamp) return null;
  const merchant = normalizeMerchant(parsed.merchant ?? parsed.rawMessage ?? '');
  const card = parsed.last4 ?? '';
  const fingerprint = await sha256Hex([
    parsed.amount.toFixed(2),
    parsed.currency.toUpperCase(),
    merchant,
    card,
    parsed.comparisonTimestamp,
  ].join('|'));
  const { data } = await supabase
    .from('capture_fingerprints')
    .select('payload_id')
    .eq('install_id_hash', installIdHash)
    .eq('fingerprint', fingerprint)
    .maybeSingle();
  if (data?.payload_id) return data.payload_id as string;
  await supabase.from('capture_fingerprints').insert({
    install_id_hash: installIdHash,
    fingerprint,
    payload_id: payloadId,
  });
  return null;
}

function buildNotification(status: CaptureStatus, parsed: ParsedCapture, sender: string): NotificationPayload {
  if (status === 'duplicate') {
    return {
      title: 'عملية مشابهة موجودة',
      body: 'العملية دي شبه عملية موجودة بنفس المبلغ والتاجر والوقت.',
      type: 'suspicious_duplicate',
    };
  }
  if (status === 'needs_review') {
    return {
      title: 'عملية تحتاج مراجعة',
      body: parsed.amount && parsed.currency
        ? `راجع ${formatAmount(parsed.amount)} ${parsed.currency}${parsed.merchant ? ` لدى ${parsed.merchant}` : ''}.`
        : 'افتح قرش لمراجعة الرسالة.',
      type: 'needs_review',
    };
  }
  if (status === 'processed') {
    const verb = parsed.direction === 'credit' ? 'إضافة' : 'تسجيل';
    return {
      title: parsed.direction === 'credit' ? 'تم رصد إيداع' : 'تم رصد عملية',
      body: `${verb} ${formatAmount(parsed.amount ?? 0)} ${parsed.currency ?? ''}${parsed.merchant ? ` لدى ${parsed.merchant}` : sender ? ` من ${sender}` : ''}.`,
      type: 'new_transaction',
    };
  }
  return {
    title: 'قِرش رصد رسالة بنك',
    body: sender ? `تم استلام رسالة من ${sender}. افتح قرش لمراجعتها.` : 'تم استلام رسالة بنكية. افتح قرش لمراجعتها.',
    type: 'received',
  };
}

async function sendApnsIfPossible(
  supabase: ReturnType<typeof serviceClient>,
  installIdHash: string,
  payloadId: string,
  notification: NotificationPayload,
  parsed: ParsedCapture,
): Promise<boolean> {
  const { data: device } = await supabase
    .from('capture_devices')
    .select('apns_token,apns_environment')
    .eq('install_id_hash', installIdHash)
    .maybeSingle();
  const token = typeof device?.apns_token === 'string' ? device.apns_token : '';
  const environment = device?.apns_environment === 'sandbox' ||
      device?.apns_environment === 'production'
    ? device.apns_environment
    : null;
  if (!token || !environment) return false;

  const result = await sendCapturePush({
    token,
    environment,
    payloadId,
    title: notification.title,
    body: notification.body,
    notificationType: notification.type,
    smartInboxItemId: notification.type === 'needs_review' ||
        notification.type === 'suspicious_duplicate'
      ? payloadId
      : undefined,
    transactionId: typeof parsed.possibleDuplicateOfTransactionId === 'string'
      ? parsed.possibleDuplicateOfTransactionId
      : undefined,
  });
  if (result.ok) {
    await supabase
      .from('processed_captures')
      .update({
        apns_push_sent_at: new Date().toISOString(),
        apns_push_error: null,
      })
      .eq('install_id_hash', installIdHash)
      .eq('payload_id', payloadId);
    return true;
  }
  await supabase
    .from('processed_captures')
    .update({ apns_push_error: result.reason })
    .eq('install_id_hash', installIdHash)
    .eq('payload_id', payloadId);
  console.warn(JSON.stringify({
    event: 'capture_apns_failed',
    payloadId,
    reason: result.reason,
  }));
  return false;
}

function normalize(input: string): string {
  let text = normalizeDigits(input);
  for (const mark of rules.normalization.decimalMarks as string[]) text = text.replaceAll(mark, '.');
  for (const mark of rules.normalization.thousandsMarks as string[]) text = text.replaceAll(mark, '');
  for (const rule of rules.normalization.currencyReplacements as Array<{ pattern: string; replacement: string }>) {
    text = text.replace(new RegExp(rule.pattern, 'gi'), rule.replacement);
  }
  while (/(\d),(\d)/.test(text)) text = text.replace(/(\d),(\d)/g, '$1$2');
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

function reSanitize(text: string): string {
  return text
    .replace(/\b\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4}\b/g, '[CARD]')
    .replace(/\b05\d{8}\b/g, '[PHONE]')
    .replace(/\b01[0125]\d{8}\b/g, '[PHONE]')
    .replace(/\+\d{7,15}\b/g, '[PHONE]')
    .replace(/\b\d{10,20}\b/g, '[ACCOUNT]')
    .trim();
}

function extractNumber(text: string, patterns: string[]): number | undefined {
  const raw = extractFirstGroup(text, patterns);
  if (!raw) return undefined;
  const value = Number(raw.replace(/,/g, ''));
  return Number.isFinite(value) ? value : undefined;
}

function extractCurrency(text: string): string | undefined {
  const match = new RegExp(rules.currencyPattern as string, 'i').exec(text);
  return match?.[1]?.toUpperCase();
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

function extractTimestamp(text: string): string | undefined {
  const now = new Date();
  const iso = /(\d{4})[-/](\d{1,2})[-/](\d{1,2})(?:[ T]+(\d{1,2}):(\d{2}))?/i.exec(text);
  if (iso) {
    return makeUtc(Number(iso[1]), Number(iso[2]), Number(iso[3]), Number(iso[4] ?? 12), Number(iso[5] ?? 0));
  }
  const dmy = /(\d{1,2})[-/](\d{1,2})(?:[-/](\d{2,4}))?(?:[ T]+(\d{1,2}):(\d{2}))?/i.exec(text);
  if (dmy) {
    const year = dmy[3] ? normalizeYear(Number(dmy[3])) : now.getUTCFullYear();
    return makeUtc(year, Number(dmy[2]), Number(dmy[1]), Number(dmy[4] ?? 12), Number(dmy[5] ?? 0));
  }
  const time = /(?:الساعة|at)\s*(\d{1,2}):(\d{2})/i.exec(text);
  if (time) {
    return makeUtc(now.getUTCFullYear(), now.getUTCMonth() + 1, now.getUTCDate(), Number(time[1]), Number(time[2]));
  }
  return undefined;
}

function normalizeYear(year: number): number {
  return year < 100 ? 2000 + year : year;
}

function makeUtc(year: number, month: number, day: number, hour: number, minute: number): string {
  return new Date(Date.UTC(year, month - 1, day, hour, minute, 0)).toISOString();
}

function normalizeMerchant(value: string): string {
  return value.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
}

function formatAmount(value: number): string {
  return Number.isInteger(value) ? String(value) : value.toFixed(2);
}
