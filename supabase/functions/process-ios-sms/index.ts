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
import { redactPii, redactThirdPartyNames } from '../_shared/sms_redaction.ts';
import { markApnsLogFailed, markApnsLogSent, upsertQueuedApnsLog } from '../_shared/notification_logs.ts';
import {
  isTransientApnsFailure,
  MAX_NOTIFICATION_RETRY_ATTEMPTS,
  nextRetryDelayMs,
} from '../_shared/notification_retry_policy.ts';
import { type FingerprintReservationStore, reserveCaptureFingerprint } from '../_shared/fingerprint_reservation.ts';
import { isDirectCaptureWriteEnabled, isLedgerDualWriteEnabled, upsertLedgerTransaction } from '../_shared/ledger.ts';
import { apiError, correlationId } from '../_shared/ai_endpoint.ts';
import { type ParsedCapture, parseSms } from './parse.ts';

export type { ParsedCapture };

export type CaptureStatus = 'processed' | 'needs_review' | 'duplicate' | 'rejected';
type NotificationPayload = {
  title: string;
  body: string;
  type: 'new_transaction' | 'needs_review' | 'suspicious_duplicate' | 'received';
};

const CAPTURE_RATE_LIMIT_PER_DAY = 300;

type ProcessIosSmsDependencies = {
  createServiceClient: typeof serviceClient;
  verifyDevice: typeof verifyDevice;
};

const defaultDependencies: ProcessIosSmsDependencies = {
  createServiceClient: serviceClient,
  verifyDevice,
};

export type CaptureProcessingConsent =
  | { ok: true; aiAllowed: boolean }
  | { ok: false; response: Response };

/// Applies the device-scoped consent contract to a fresh capture_devices read.
/// Cloud processing is the master gate for ALL parsing/storage/delivery work in
/// this endpoint. AI is a narrower, additional grant and never bypasses cloud.
export function captureProcessingConsent(
  consent: {
    data: {
      ai_consent_granted?: unknown;
      cloud_processing_enabled?: unknown;
      revoked_at?: unknown;
    } | null;
    error: unknown;
  },
  allowAi: boolean,
  cid: string,
): CaptureProcessingConsent {
  if (consent.data?.revoked_at != null) {
    return { ok: false, response: apiError('credential_revoked', { correlationId: cid }) };
  }
  if (consent.error || !consent.data || consent.data.cloud_processing_enabled !== true) {
    return { ok: false, response: apiError('consent_required', { correlationId: cid }) };
  }
  return {
    ok: true,
    aiAllowed: allowAi && consent.data.ai_consent_granted === true,
  };
}

export async function handleProcessIosSms(
  req: Request,
  dependencies: ProcessIosSmsDependencies = defaultDependencies,
): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response(null, { headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);
  const cid = correlationId();

  // MALI-060n — gate ordering. Every gate below completes BEFORE any Gemini
  // (paid upstream) call, which lives in parseSms():
  //   1. body-size   → readBoundedJsonBody (does not trust Content-Length)
  //   2. schema      → schema_version === 1
  //   2b. length     → bounded SMS / sender / field lengths
  //   3. device auth → verifyDevice (device secret)
  //   4. ownership   → auth.userId / auth.installIdHash (server-derived)
  //   5. consent     → server cloud master gate, then optional AI grant
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
  // Sanitized too. This was taken VERBATIM from the body and copied into
  // `parsed.rawMessage`, which is persisted for every capture — not only the
  // needs_review/rejected ones that store `sanitized_text`. Both shipping
  // clients sanitize before sending, so this was the missing defence-in-depth
  // layer rather than a live leak, but it is exactly the layer `07_SECURITY.md`
  // says must be preserved, and a wire probe confirmed the raw text came
  // straight back in the response.
  const rawText = reSanitize(readString(body, 'smsText', 'sms_text')) || sanitizedText;
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

  const supabase = dependencies.createServiceClient();
  const auth = await dependencies.verifyDevice(supabase, installId, deviceSecret);
  if (!auth.ok) return json({ error: auth.error }, auth.status);

  // Fresh server authority on every request, before idempotency lookup, parse,
  // storage, ledger writes, or APNs. Missing/error/OFF fails closed. This local
  // processing gate deliberately does not change verifyDevice: sync-captures is
  // delivery-only and may still return captures processed before revocation.
  const consent = await supabase
    .from('capture_devices')
    .select('ai_consent_granted, cloud_processing_enabled, revoked_at')
    .eq('install_id_hash', auth.installIdHash)
    .maybeSingle();
  const consentGate = captureProcessingConsent(consent, allowAi, cid);
  if (!consentGate.ok) return consentGate.response;
  const aiAllowed = consentGate.aiAllowed;

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

  const outcome = await parseSms({
    text: sanitizedText,
    rawText,
    sender,
    receivedAt,
    tzOffsetMinutes,
    locale,
    // Server-authoritative: never the raw caller flag.
    allowAi: aiAllowed,
  });
  const parsed = outcome.parsed;

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
  // Binary outcome: parseSms decides accepted/rejected deterministically (AI
  // confidence never matters). New captures are never 'needs_review'; that
  // value stays in CaptureStatus only because legacy rows/clients still carry it.
  let status = (outcome.accepted && parsed.amount && parsed.currency ? 'processed' : 'rejected') as CaptureStatus;

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
}

if (import.meta.main) Deno.serve((req) => handleProcessIosSms(req));

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

export function buildNotification(
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
  // The transaction's NATURE, on every template.
  //
  // `typeTitle` already exposes this, but only inside the `processed` title;
  // `duplicate` and `needs_review` hardcode their titles, so a real iPhone
  // showed "عملية مشابهة" with the amount, merchant, card and time and no hint
  // of whether money left or entered the account — data the parse already had.
  // Putting it in detailLines fixes all three templates at once instead of
  // patching two more titles.
  const nature = natureLabelAr(parsed);
  if (nature) lines.push(`النوع: ${nature}`);
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

/// The nature of the movement, from the same `direction`/`type` the parser
/// already produces. Direction wins because it is the grounded signal
/// (`detectDirection`); `type` only refines it.
///
/// Returns null when the parse could not classify, so an unknown movement stays
/// silent rather than being asserted as an expense.
function natureLabelAr(parsed: ParsedCapture): string | null {
  if (parsed.direction === 'credit' || parsed.type === 'income') return 'دخل';
  switch (parsed.type) {
    case 'transfer':
      return 'تحويل';
    case 'refund':
      return 'استرداد';
    case 'withdrawal':
      return 'سحب نقدي';
    case 'payment':
      return 'مصروف';
    default:
      return parsed.direction === 'debit' ? 'مصروف' : null;
  }
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
    notificationLogId,
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

function reSanitize(text: string): string {
  // This copy was missing the IBAN and OTP rules while forwarding the result
  // to Gemini, so a full IBAN reached the model. Delegated to the shared floor
  // rather than re-typed, so the three server copies cannot drift again.
  return redactThirdPartyNames(redactPii(text)).trim();
}

function normalizeMerchant(value: string): string {
  return value.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
}

function formatAmount(value: number): string {
  return Number.isInteger(value) ? String(value) : value.toFixed(2);
}
