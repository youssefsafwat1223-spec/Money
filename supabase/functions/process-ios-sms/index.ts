import rules from './parser_rules.json' with { type: 'json' };
import {
  corsHeaders,
  json,
  readBoundedJsonBody,
  readString,
  serviceClient,
  sha256Hex,
  verifyDevice,
} from '../_shared/capture_auth.ts';
import { sendCapturePush } from '../_shared/apns.ts';
import { fingerprintTimeKeys } from '../_shared/capture_fingerprint.ts';
import { markApnsLogFailed, markApnsLogSent, upsertQueuedApnsLog } from '../_shared/notification_logs.ts';
import {
  isTransientApnsFailure,
  MAX_NOTIFICATION_RETRY_ATTEMPTS,
  nextRetryDelayMs,
} from '../_shared/notification_retry_policy.ts';
import { type FingerprintReservationStore, reserveCaptureFingerprint } from '../_shared/fingerprint_reservation.ts';
import { isDirectCaptureWriteEnabled, isLedgerDualWriteEnabled, upsertLedgerTransaction } from '../_shared/ledger.ts';
import { extractCaptureAmount, withValidatedModelAmountText } from './money.ts';

type CaptureStatus = 'processed' | 'needs_review' | 'duplicate' | 'rejected';
type ParsedCapture = {
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

type NotificationPayload = {
  title: string;
  body: string;
  type: 'new_transaction' | 'needs_review' | 'suspicious_duplicate' | 'received';
};

const CAPTURE_RATE_LIMIT_PER_DAY = 300;
const CURRENCY_CODES = ['SAR', 'AED', 'EGP', 'QAR', 'OMR', 'KWD', 'BHD', 'JOD', 'USD', 'EUR', 'GBP', 'JPY'];
const GEMINI_MODEL = Deno.env.get('GEMINI_MODEL') ?? 'gemini-2.5-flash-lite';
const GEMINI_API_KEY = Deno.env.get('GEMINI_API_KEY') ?? '';
const GEMINI_URL = `https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent`;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);

  // MALI-060n — gate ordering. Every gate below completes BEFORE any Gemini
  // (paid upstream) call, which lives in parseSms():
  //   1. body-size   → readBoundedJsonBody (does not trust Content-Length)
  //   2. schema      → schema_version === 1
  //   2b. length     → bounded SMS / sender / field lengths
  //   3. device auth → verifyDevice (device secret)
  //   4. ownership   → auth.userId / auth.installIdHash (server-derived)
  //   5. consent     → server-owned ai_consent_granted (allowAi is compat-only)
  //   (idempotency replay is checked before the quota bump ON PURPOSE, so a
  //    legitimate lost-response retry does not consume quota; both still precede
  //    parseSms.)
  //   6. quota       → bumpRateLimit
  //   7. idempotency → processed_captures existence
  const MAX_BODY_BYTES = 16 * 1024; // one SMS + metadata; generous, bounded.
  const bodyResult = await readBoundedJsonBody(req, MAX_BODY_BYTES);
  if (!bodyResult.ok) {
    const status = bodyResult.reason === 'too_large' ? 413 : bodyResult.reason === 'unsupported_media_type' ? 415 : 400;
    return json({ error: bodyResult.reason }, status);
  }
  const body = bodyResult.body;

  // Strict schema version (reject unexpected/expensive modes early).
  const schemaVersion = typeof body.schema_version === 'number'
    ? body.schema_version
    : typeof body.schemaVersion === 'number'
    ? body.schemaVersion
    : 1;
  if (schemaVersion !== 1) return json({ error: 'unsupported_schema_version' }, 400);

  const installId = readString(body, 'installId', 'install_id');
  const deviceSecret = readString(body, 'deviceSecret', 'device_secret');
  const payloadId = readString(body, 'payloadId', 'payload_id');
  const sanitizedText = reSanitize(readString(body, 'sanitizedText', 'sanitized_text', 'smsText', 'sms_text'));
  const rawText = readString(body, 'smsText', 'sms_text') || sanitizedText;
  const sender = readString(body, 'sender', 'senderId', 'sender_id', 'senderName', 'sender_name');
  const receivedAt = readString(body, 'receivedAt', 'received_at') || new Date().toISOString();
  const tzOffsetMinutes = typeof body.tzOffsetMinutes === 'number' ? body.tzOffsetMinutes : null;
  const locale = readString(body, 'locale', 'deviceLocale', 'device_locale');
  const allowAi = body.allowAi === true || body.allow_ai === true;

  if (!payloadId || !sanitizedText) {
    return json({ error: 'missing_fields' }, 400);
  }
  // Bounded field lengths (defence in depth beyond the byte cap).
  const MAX_SMS_CHARS = 2000;
  const MAX_SENDER_CHARS = 64;
  const MAX_PAYLOAD_ID_CHARS = 200;
  if (sanitizedText.length > MAX_SMS_CHARS || rawText.length > MAX_SMS_CHARS) {
    return json({ error: 'payload_too_large' }, 413);
  }
  if (sender.length > MAX_SENDER_CHARS || payloadId.length > MAX_PAYLOAD_ID_CHARS) {
    return json({ error: 'invalid_fields' }, 400);
  }

  const supabase = serviceClient();
  const auth = await verifyDevice(supabase, installId, deviceSecret);
  if (!auth.ok) return json({ error: auth.error }, auth.status);

  // MALI-060n — AI authority is the SERVER-owned per-device consent record, not
  // the caller's allowAi flag. allowAi is compatibility metadata only: AI runs
  // only when the verified device has BOTH granted consent AND requested it, so
  // allowAi=true can never override a server OFF, and a revoked credential
  // blocks AI on the very next request. The read fails CLOSED (missing row /
  // absent column / any error ⇒ consent OFF), which also keeps this correct
  // while migration 0071 is undeployed (server AI simply stays off; the client
  // degrades to a local parse).
  const consent = await supabase
    .from('capture_devices')
    .select('ai_consent_granted, revoked_at')
    .eq('install_id_hash', auth.installIdHash)
    .maybeSingle();
  const serverAiConsent = !consent.error && !!consent.data &&
    consent.data.ai_consent_granted === true && consent.data.revoked_at == null;
  const aiAllowed = allowAi && serverAiConsent;

  const existing = await supabase
    .from('processed_captures')
    .select('payload_id,status,parsed,notification,created_at,apns_push_sent_at,notification_log_id')
    .eq('payload_id', payloadId)
    .eq('install_id_hash', auth.installIdHash)
    .maybeSingle();
  if (existing.data) {
    return json(
      await idempotentReplayResponse(
        supabase,
        auth.installIdHash,
        installId,
        auth.userId,
        payloadId,
        existing.data,
      ),
    );
  }

  const limited = await bumpRateLimit(supabase, auth.installIdHash);
  if (limited) return json({ error: 'rate_limit_exceeded' }, 429);

  const parsed = await parseSms({
    text: sanitizedText,
    rawText,
    sender,
    receivedAt,
    tzOffsetMinutes,
    locale,
    // Server-authoritative: never the raw caller flag.
    allowAi: aiAllowed,
  });

  // Metadata only — never the raw SMS, sender, amount, merchant, secret, or body.
  console.log(JSON.stringify({
    event: 'sms_parse_result',
    hasAmount: parsed.amount != null,
    hasCurrency: parsed.currency != null,
    type: parsed.type ?? null,
    hasMerchant: parsed.merchant != null,
    confidence: parsed.confidence ?? null,
    parserSource: parsed.parserSource ?? null,
    aiRequested: allowAi,
    aiApplied: aiAllowed,
  }));

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

  const notification = buildNotification(status, parsed, sender, receivedAt, tzOffsetMinutes);
  const { data, error } = await supabase
    .from('processed_captures')
    .insert({
      payload_id: payloadId,
      install_id_hash: auth.installIdHash,
      claimed_user_id: auth.userId,
      status,
      parsed,
      notification,
      sanitized_text: status === 'needs_review' || status === 'rejected' ? sanitizedText : null,
      raw_fingerprint: rawFingerprint,
      failure_reason: status === 'rejected' ? 'not_parseable' : null,
    })
    .select('payload_id,status,parsed,notification,created_at,apns_push_sent_at,notification_log_id')
    .single();

  if (error) {
    // Concurrent duplicate call (same payload raced past the existence check):
    // converge on the winner's row instead of failing — a 500 here makes the
    // App Intent post a local fallback banner on top of the winner's APNs push.
    if (error.code === '23505') {
      const winner = await supabase
        .from('processed_captures')
        .select('payload_id,status,parsed,notification,created_at,apns_push_sent_at,notification_log_id')
        .eq('payload_id', payloadId)
        .eq('install_id_hash', auth.installIdHash)
        .maybeSingle();
      if (winner.data) {
        return json(
          await idempotentReplayResponse(
            supabase,
            auth.installIdHash,
            installId,
            auth.userId,
            payloadId,
            winner.data,
          ),
        );
      }
    }
    return json({ error: 'store_failed' }, 500);
  }

  console.log(JSON.stringify({
    event: 'capture_stored',
    status,
  }));

  // Safety rollout: relay storage above is always preserved. Direct capture is
  // allowed only when both the dedicated capture flag and transaction-primary
  // routing are enabled for this signed-in user. The legacy dual-write flag
  // remains supported independently during rollback validation.
  let serverTransactionId: string | undefined;
  if (auth.userId && (status === 'processed' || status === 'needs_review')) {
    try {
      const directWriteEnabled = await isDirectCaptureWriteEnabled(supabase, auth.userId);
      const dualWriteEnabled = directWriteEnabled ? false : await isLedgerDualWriteEnabled(supabase, auth.userId);
      if (directWriteEnabled || dualWriteEnabled) {
        const ledger = await upsertLedgerTransaction(supabase, auth.userId, {
          payloadId,
          amount: parsed.amount!,
          amountText: parsed.amount_text,
          currency: parsed.currency!,
          direction: parsed.direction,
          type: parsed.type,
          merchant: parsed.merchant,
          categoryId: parsed.category,
          occurredAt: parsed.occurredAt ?? receivedAt,
          confidence: parsed.confidence,
          last4: parsed.last4,
          status: status === 'needs_review' ? 'pending' : 'confirmed',
          comparisonTimestamp: parsed.comparisonTimestamp,
          comparisonTimestampSource: parsed.comparisonTimestampSource,
          transactionTimeFromSms: parsed.comparisonTimestampSource === 'sms_body'
            ? parsed.comparisonTimestamp
            : undefined,
          smsReceivedAt: receivedAt,
          parserSource: parsed.parserSource,
        });
        if (directWriteEnabled) {
          serverTransactionId = ledger.id;
          parsed.serverTransactionId = ledger.id;
          await supabase
            .from('processed_captures')
            .update({ parsed })
            .eq('install_id_hash', auth.installIdHash)
            .eq('payload_id', payloadId);
        }
      }
    } catch (err) {
      // Non-fatal: the relay row remains available to Flutter for Phase 1
      // import. Do not expose payload identifiers or SMS contents in logs.
      console.warn(JSON.stringify({ event: 'capture_ledger_write_failed', errorType: String(err).split(':')[0] }));
    }
  }

  const pushSent = await sendApnsIfPossible(
    supabase,
    auth.installIdHash,
    installId,
    auth.userId,
    payloadId,
    notification,
    parsed,
    serverTransactionId,
  );
  console.log(JSON.stringify({
    event: 'process_ios_sms_complete',
    status,
    pushSent,
  }));
  return json({
    capture: {
      ...data,
      parsed,
      apns_push_sent_at: pushSent ? new Date().toISOString() : data.apns_push_sent_at,
    },
    pushSent,
  });
});

// Replay of an already-stored payload (the App Intent retries after a client
// timeout). If APNs was never confirmed sent, try again now: the stable
// apns-collapse-id per payloadId means a re-send replaces the earlier banner
// instead of duplicating it, and this closes the race where a replay read
// `apns_push_sent_at` between the original send and its DB write — returning
// pushSent=false would make the intent post a duplicate local banner.
async function idempotentReplayResponse(
  supabase: ReturnType<typeof serviceClient>,
  installIdHash: string,
  installId: string,
  userId: string | null,
  payloadId: string,
  row: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  let pushSent = Boolean(row.apns_push_sent_at);
  const notification = row.notification as NotificationPayload | null;
  const parsed = (row.parsed ?? {}) as ParsedCapture;
  if (!pushSent && notification?.title && notification?.body) {
    pushSent = await sendApnsIfPossible(
      supabase,
      installIdHash,
      installId,
      userId,
      payloadId,
      notification,
      parsed,
      typeof parsed.serverTransactionId === 'string' ? parsed.serverTransactionId : undefined,
    );
  }
  console.log(JSON.stringify({ event: 'capture_idempotent_replay', pushSent }));
  return {
    capture: {
      ...row,
      apns_push_sent_at: pushSent ? (row.apns_push_sent_at ?? new Date().toISOString()) : row.apns_push_sent_at,
    },
    idempotent: true,
    pushSent,
  };
}

async function bumpRateLimit(
  supabase: ReturnType<typeof serviceClient>,
  installIdHash: string,
): Promise<boolean> {
  // Atomic increment via RPC (migration 0028). Falls back to the legacy
  // read-then-upsert if the function is not deployed yet, so the endpoint
  // never breaks on migration-ordering during rollout.
  const atomic = await supabase.rpc('bump_capture_rate_limit', {
    p_install_id_hash: installIdHash,
    p_limit: CAPTURE_RATE_LIMIT_PER_DAY,
  });
  if (!atomic.error && typeof atomic.data === 'boolean') {
    return atomic.data;
  }
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
  tzOffsetMinutes: number | null;
  locale: string;
  allowAi: boolean;
}): Promise<ParsedCapture> {
  const deterministic = deterministicParse(
    input.text,
    input.receivedAt,
    input.tzOffsetMinutes,
  );

  if (input.allowAi) {
    const ai = await aiParse(input.text);
    const deterministicAmount = deterministic.amount != null;
    const amount = deterministicAmount ? deterministic.amount : ai?.amount;
    const amount_text = deterministicAmount ? deterministic.amount_text : ai?.amount_text;
    const currency = normalizeCurrencyCode(deterministic.currency) ??
      normalizeCurrencyCode(ai?.currency);
    if (ai && amount != null && currency) {
      const aiTimestamp = trustedSmsTimestamp(
        ai.occurredAt,
        input.receivedAt,
        input.tzOffsetMinutes,
      );
      const deterministicTimestamp = deterministic.comparisonTimestampSource === 'sms_body'
        ? trustedSmsTimestamp(
          deterministic.comparisonTimestamp,
          input.receivedAt,
          input.tzOffsetMinutes,
        )
        : undefined;
      const comparisonTimestamp = deterministicTimestamp ?? aiTimestamp ?? input.receivedAt;
      return {
        amount,
        ...(amount_text == null ? {} : { amount_text }),
        currency,
        type: ai.type ?? deterministic.type,
        merchant: ai.merchant ?? deterministic.merchant,
        category: ai.category ?? deterministic.category,
        last4: ai.last4 ?? deterministic.last4,
        direction: ai.direction ?? deterministic.direction,
        confidence: Math.max(ai.confidence ?? 0.82, deterministic.confidence ?? 0),
        rawMessage: input.rawText,
        senderId: input.sender || undefined,
        occurredAt: comparisonTimestamp,
        comparisonTimestamp,
        comparisonTimestampSource: deterministicTimestamp || aiTimestamp ? 'sms_body' : 'received_at',
        parserSource: 'ai_hybrid',
      };
    }
  }

  return {
    ...deterministic,
    rawMessage: input.rawText,
    senderId: input.sender || undefined,
    parserSource: 'deterministic',
  };
}

function deterministicParse(
  text: string,
  receivedAt: string,
  tzOffsetMinutes: number | null,
): ParsedCapture {
  const normalized = normalize(text);
  const lower = normalized.toLowerCase();
  const ignored = (rules.ignoreKeywords as string[]).some((keyword) => lower.includes(keyword.toLowerCase()));
  if (ignored) return { confidence: 0, comparisonTimestamp: receivedAt, comparisonTimestampSource: 'received_at' };

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

async function aiParse(text: string): Promise<ParsedCapture | null> {
  if (!GEMINI_API_KEY) return null;
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
    const response = await fetch(GEMINI_URL, {
      signal: AbortSignal.timeout(3500),
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
    const withExactText = parsed && typeof parsed === 'object'
      ? withValidatedModelAmountText(parsed as Record<string, unknown>)
      : {};
    return {
      amount: typeof withExactText.amount === 'number' ? withExactText.amount : undefined,
      amount_text: typeof withExactText.amount_text === 'string' ? withExactText.amount_text : undefined,
      currency: typeof withExactText.currency === 'string' ? withExactText.currency.toUpperCase() : undefined,
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
  const base = [
    parsed.amount.toFixed(2),
    parsed.currency.toUpperCase(),
    merchant,
    card,
  ].join('|');

  // Exact for sms_body timestamps; bucketed (~10–20 min window) for
  // received_at ones — see _shared/capture_fingerprint.ts and its tests.
  const timeKeys = fingerprintTimeKeys(
    parsed.comparisonTimestamp,
    parsed.comparisonTimestampSource,
  );

  const fingerprints = await Promise.all(
    timeKeys.map((key) => sha256Hex(`${base}|${key}`)),
  );
  const store: FingerprintReservationStore = {
    async insert(row) {
      const { error } = await supabase.from('capture_fingerprints').insert(row);
      return { error };
    },
    async find(hash, keys) {
      const { data, error } = await supabase
        .from('capture_fingerprints')
        .select('payload_id,fingerprint')
        .eq('install_id_hash', hash)
        .in('fingerprint', keys);
      return { data, error };
    },
  };
  return reserveCaptureFingerprint(
    store,
    installIdHash,
    payloadId,
    fingerprints,
  );
}

function buildNotification(
  status: CaptureStatus,
  parsed: ParsedCapture,
  sender: string,
  receivedAt: string,
  tzOffsetMinutes: number | null,
): NotificationPayload {
  if (status === 'duplicate') {
    return {
      title: 'عملية مشابهة ⚠️',
      body: `${detailLines(parsed, receivedAt, tzOffsetMinutes)}\nموجودة مسبقاً؟ افتح قرش للمراجعة.`,
      type: 'suspicious_duplicate',
    };
  }
  if (status === 'needs_review') {
    return {
      title: 'عملية تحتاج مراجعة ⚠️',
      body: parsed.amount && parsed.currency
        ? `${detailLines(parsed, receivedAt, tzOffsetMinutes)}\nافتح قرش للمراجعة والتأكيد.`
        : 'افتح قرش لمراجعة الرسالة.',
      type: 'needs_review',
    };
  }
  if (status === 'processed') {
    return {
      title: `تم رصد ${typeTitle(parsed)} ${typeEmoji(parsed)}`,
      body: detailLines(parsed, receivedAt, tzOffsetMinutes),
      type: 'new_transaction',
    };
  }
  // rejected: لا يُنشأ أي عنصر داخل التطبيق (الـ relay يُحذف بعد الـ ack)،
  // فلا نَعِد المستخدم بمراجعة غير موجودة — نرشده للّصق اليدوي بدلاً منها.
  return {
    title: 'قِرش رصد رسالة بنك',
    body: sender
      ? `رسالة من ${sender} لم نتمكن من تحليلها. الصقها يدوياً في قرش لإضافتها.`
      : 'رسالة بنكية لم نتمكن من تحليلها. الصقها يدوياً في قرش لإضافتها.',
    type: 'received',
  };
}

// قائمة التفاصيل — سطر لكل معلومة متاحة. الرصيد لا يظهر أبداً (شاشة القفل).
function detailLines(
  parsed: ParsedCapture,
  receivedAt: string,
  tzOffsetMinutes: number | null,
): string {
  const lines = [`المبلغ: ${formatAmount(parsed.amount ?? 0)} ${parsed.currency ?? ''}`.trim()];
  if (parsed.merchant) {
    lines.push(parsed.direction === 'credit' ? `المصدر: ${parsed.merchant}` : `التاجر: ${parsed.merchant}`);
  }
  if (parsed.last4) lines.push(`البطاقة: ****${parsed.last4}`);
  const time = timeLabel(parsed.occurredAt ?? receivedAt, tzOffsetMinutes);
  if (time) lines.push(`الوقت: ${time}`);
  const category = categoryLabelAr(parsed.category);
  if (category) lines.push(`التصنيف: ${category}`);
  return lines.join('\n');
}

function typeTitle(parsed: ParsedCapture): string {
  if (parsed.direction === 'credit') return 'إيداع';
  switch (parsed.type) {
    case 'withdrawal':
      return 'سحب نقدي';
    case 'transfer':
      return 'تحويل';
    case 'refund':
      return 'استرداد';
    case 'payment':
      return 'عملية شراء';
    default:
      return 'عملية';
  }
}

function typeEmoji(parsed: ParsedCapture): string {
  if (parsed.direction === 'credit') return '💰';
  switch (parsed.type) {
    case 'withdrawal':
      return '🏧';
    case 'transfer':
      return '🔁';
    case 'refund':
      return '↩️';
    case 'payment':
      return '🛒';
    default:
      return '💳';
  }
}

// "اليوم 9:41 م" بتوقيت الجهاز (عبر tzOffsetMinutes). بدون offset لا نعرض وقتاً
// حتى لا نعرض توقيت UTC مضللاً.
function timeLabel(iso: string, tzOffsetMinutes: number | null): string | null {
  if (tzOffsetMinutes == null) return null;
  const utc = new Date(iso);
  if (Number.isNaN(utc.getTime())) return null;
  const local = new Date(utc.getTime() + tzOffsetMinutes * 60_000);
  const nowLocal = new Date(Date.now() + tzOffsetMinutes * 60_000);
  const hour24 = local.getUTCHours();
  const hour12 = hour24 % 12 === 0 ? 12 : hour24 % 12;
  const minute = String(local.getUTCMinutes()).padStart(2, '0');
  const suffix = hour24 < 12 ? 'ص' : 'م';
  const time = `${hour12}:${minute} ${suffix}`;
  const sameDay = local.getUTCFullYear() === nowLocal.getUTCFullYear() &&
    local.getUTCMonth() === nowLocal.getUTCMonth() &&
    local.getUTCDate() === nowLocal.getUTCDate();
  if (sameDay) return `اليوم ${time}`;
  const yesterday = new Date(nowLocal.getTime() - 86_400_000);
  const isYesterday = local.getUTCFullYear() === yesterday.getUTCFullYear() &&
    local.getUTCMonth() === yesterday.getUTCMonth() &&
    local.getUTCDate() === yesterday.getUTCDate();
  if (isYesterday) return `أمس ${time}`;
  return `${local.getUTCDate()}/${local.getUTCMonth() + 1} ${time}`;
}

// نفس تسميات lib/features/capture/services/capture_notification_content.dart.
function categoryLabelAr(key: string | undefined): string | null {
  switch (key) {
    case 'restaurants':
      return 'مطاعم 🍔';
    case 'cafes':
      return 'مقاهي ☕';
    case 'groceries':
      return 'بقالة 🛒';
    case 'transport':
      return 'مواصلات 🚗';
    case 'fuel':
      return 'وقود ⛽';
    case 'bills':
      return 'فواتير 📱';
    case 'shopping':
      return 'تسوق 🛍';
    case 'health':
      return 'صحة 🏥';
    case 'education':
      return 'تعليم 📚';
    case 'entertainment':
      return 'ترفيه 🎬';
    case 'subscriptions':
      return 'اشتراكات 📲';
    case 'transfers':
      return 'تحويل 💸';
    case 'cash':
      return 'كاش 💵';
    case 'travel':
      return 'سفر ✈️';
    case 'gifts':
      return 'هدايا 🎁';
    case 'kids':
      return 'أطفال 👶';
    case 'home':
      return 'منزل 🏠';
    case 'maintenance':
      return 'صيانة 🔧';
    case 'fitness':
      return 'رياضة 💪';
    case 'beauty':
      return 'جمال 💅';
    case 'charity':
      return 'خيرية 🤲';
    case 'pets':
      return 'حيوانات 🐾';
    case 'insurance':
      return 'تأمين 🛡️';
    case 'income':
      return 'دخل 💰';
    default:
      return null;
  }
}

// Reuses the same notification_log_id across a replay/retry of the same
// payload (stored on processed_captures) rather than minting a new one per
// attempt — see docs/NOTIFICATION_PIPELINE_AUDIT.md Phase 1, item 2.
async function ensureNotificationLogId(
  supabase: ReturnType<typeof serviceClient>,
  installIdHash: string,
  payloadId: string,
): Promise<string> {
  const { data } = await supabase
    .from('processed_captures')
    .select('notification_log_id')
    .eq('install_id_hash', installIdHash)
    .eq('payload_id', payloadId)
    .maybeSingle();
  const existing = data?.notification_log_id;
  if (typeof existing === 'string' && existing) return existing;
  const id = crypto.randomUUID();
  await supabase
    .from('processed_captures')
    .update({ notification_log_id: id })
    .eq('install_id_hash', installIdHash)
    .eq('payload_id', payloadId);
  return id;
}

async function sendApnsIfPossible(
  supabase: ReturnType<typeof serviceClient>,
  installIdHash: string,
  installId: string,
  userId: string | null,
  payloadId: string,
  notification: NotificationPayload,
  parsed: ParsedCapture,
  serverTransactionId?: string,
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
  if (!token || !environment) {
    console.log(JSON.stringify({
      event: 'apns_skipped',
      reason: !token ? 'no_token' : 'no_environment',
    }));
    return false;
  }

  const notificationLogId = await ensureNotificationLogId(supabase, installIdHash, payloadId);
  await upsertQueuedApnsLog(supabase, {
    id: notificationLogId,
    userId,
    installId,
    notificationType: notification.type,
    relatedEntityType: 'payload',
    relatedEntityId: payloadId,
    apnsEnvironment: environment,
  });
  console.log(JSON.stringify({
    event: 'notification_created',
    notificationLogId,
    channel: 'apns',
    notificationType: notification.type,
    platform: 'ios',
  }));

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
    transactionId: serverTransactionId ??
      (typeof parsed.possibleDuplicateOfTransactionId === 'string'
        ? parsed.possibleDuplicateOfTransactionId
        : undefined),
  });
  if (result.ok) {
    console.log(JSON.stringify({
      event: 'apns_sent',
      environment,
    }));
    await supabase
      .from('processed_captures')
      .update({
        apns_push_sent_at: new Date().toISOString(),
        apns_push_error: null,
      })
      .eq('install_id_hash', installIdHash)
      .eq('payload_id', payloadId);
    await markApnsLogSent(supabase, notificationLogId, result.apnsId);
    console.log(JSON.stringify({
      event: 'notification_sent',
      notificationLogId,
      channel: 'apns',
      notificationType: notification.type,
    }));
    return true;
  }

  await supabase
    .from('processed_captures')
    .update({ apns_push_error: result.reason })
    .eq('install_id_hash', installIdHash)
    .eq('payload_id', payloadId);
  await markApnsLogFailed(supabase, notificationLogId, {
    errorCode: result.errorCode,
    errorReason: result.reason,
    retryCount: 0,
  });
  console.warn(JSON.stringify({
    event: 'notification_failed',
    notificationLogId,
    channel: 'apns',
    notificationType: notification.type,
    attempt: 1,
    errorCode: result.errorCode,
  }));

  if (isTransientApnsFailure(result.httpStatus, result.errorCode)) {
    await supabase.from('notification_retry_queue').insert({
      notification_log_id: notificationLogId,
      install_id_hash: installIdHash,
      payload_id: payloadId,
      attempt_number: 1,
      max_attempts: MAX_NOTIFICATION_RETRY_ATTEMPTS,
      next_attempt_at: new Date(Date.now() + nextRetryDelayMs(1)).toISOString(),
      last_error_code: result.errorCode,
    });
    console.log(JSON.stringify({
      event: 'notification_retry_scheduled',
      notificationLogId,
      attempt: 1,
    }));
  } else {
    console.log(JSON.stringify({
      event: 'notification_retry_exhausted',
      notificationLogId,
      reason: 'permanent_failure',
      errorCode: result.errorCode,
    }));
  }
  return false;
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

function reSanitize(text: string): string {
  return text
    .replace(/\b\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4}\b/g, '[CARD]')
    .replace(/\b05\d{8}\b/g, '[PHONE]')
    .replace(/\b01[0125]\d{8}\b/g, '[PHONE]')
    .replace(/\+\d{7,15}\b/g, '[PHONE]')
    .replace(/\b\d{10,20}\b/g, '[ACCOUNT]')
    .trim();
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

function normalizeMerchant(value: string): string {
  return value.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
}

function formatAmount(value: number): string {
  return Number.isInteger(value) ? String(value) : value.toFixed(2);
}
