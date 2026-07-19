// Drains due rows from notification_retry_queue and re-attempts the APNs
// send. Invoked periodically by pg_cron (see
// supabase/migrations/0052_notification_logs.sql,
// run_notification_retry_dispatch). See
// docs/NOTIFICATION_PIPELINE_AUDIT.md Phase 1, item 8 — retries are durable
// rows processed here, never a sleep loop inside process-ios-sms.
import { corsHeaders, json, serviceClient, timingSafeEqual } from '../_shared/capture_auth.ts';
import { sendCapturePush } from '../_shared/apns.ts';
import { markApnsLogFailed, markApnsLogSent } from '../_shared/notification_logs.ts';
import { isTransientApnsFailure, nextRetryDelayMs } from '../_shared/notification_retry_policy.ts';

type NotificationPayload = {
  title: string;
  body: string;
  type: 'new_transaction' | 'needs_review' | 'suspicious_duplicate' | 'received';
};

const BATCH_SIZE = 25;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: corsHeaders });

  // Admin-only: this function is invoked by the scheduled pg_cron dispatch
  // (which authenticates with a dedicated worker secret) or manually by an
  // operator, never by a client. Gated by NOTIFICATION_RETRY_WORKER_SECRET
  // (set via `supabase secrets set`), not SUPABASE_SERVICE_ROLE_KEY: that
  // name is platform-reserved and its value is rotated/managed by Supabase
  // itself (confirmed to differ from the project's actual service-role JWT
  // — see the identical note in purge-scheduled-deletions/index.ts), so its
  // plaintext isn't something a caller could ever be given to present back.
  const authHeader = req.headers.get('authorization') ?? '';
  const token = authHeader.startsWith('Bearer ') ? authHeader.slice(7) : '';
  const workerSecret = Deno.env.get('NOTIFICATION_RETRY_WORKER_SECRET') ?? '';
  if (!workerSecret || !timingSafeEqual(token, workerSecret)) {
    return json({ error: 'unauthorized' }, 401);
  }

  const supabase = serviceClient();
  // Atomic claim (FOR UPDATE SKIP LOCKED under the hood) so two overlapping
  // dispatch invocations can never claim, and therefore never send an APNs
  // push for, the same row — see claim_notification_retries() in
  // 0052_notification_logs.sql.
  const due = await supabase.rpc('claim_notification_retries', {
    p_limit: BATCH_SIZE,
  });

  if (due.error) {
    console.error(JSON.stringify({ event: 'notification_retry_dispatch_failed', error: due.error.message }));
    return json({ error: 'query_failed' }, 500);
  }

  let processed = 0;
  let resolvedOk = 0;
  let exhausted = 0;

  for (const row of due.data ?? []) {
    processed++;
    const outcome = await processOne(
      supabase,
      row as {
        id: string;
        notification_log_id: string;
        install_id_hash: string;
        payload_id: string;
        attempt_number: number;
        max_attempts: number;
      },
    );
    if (outcome === 'sent') resolvedOk++;
    if (outcome === 'exhausted') exhausted++;
  }

  console.log(JSON.stringify({
    event: 'notification_retry_dispatch_complete',
    processed,
    resolvedOk,
    exhausted,
  }));
  return json({ processed, resolvedOk, exhausted });
});

export async function processOne(
  supabase: ReturnType<typeof serviceClient>,
  row: {
    id: string;
    notification_log_id: string;
    install_id_hash: string;
    payload_id: string;
    attempt_number: number;
    max_attempts: number;
  },
): Promise<'sent' | 'retrying' | 'exhausted' | 'skipped'> {
  const [{ data: capture }, { data: device }] = await Promise.all([
    supabase
      .from('processed_captures')
      .select('notification,apns_push_sent_at')
      .eq('install_id_hash', row.install_id_hash)
      .eq('payload_id', row.payload_id)
      .maybeSingle(),
    supabase
      .from('capture_devices')
      .select('apns_token,apns_environment')
      .eq('install_id_hash', row.install_id_hash)
      .maybeSingle(),
  ]);

  // Already sent by a different path (e.g. a live replay) — resolve quietly.
  if (capture?.apns_push_sent_at) {
    await supabase
      .from('notification_retry_queue')
      .update({ resolved_at: new Date().toISOString() })
      .eq('id', row.id);
    return 'skipped';
  }

  const notification = capture?.notification as NotificationPayload | undefined;
  const token = typeof device?.apns_token === 'string' ? device.apns_token : '';
  const environment = device?.apns_environment === 'sandbox' || device?.apns_environment === 'production'
    ? device.apns_environment
    : null;
  if (!notification?.title || !notification?.body || !token || !environment) {
    // Nothing sendable anymore (token revoked, row pruned) — give up cleanly.
    await Promise.all([
      supabase
        .from('notification_retry_queue')
        .update({ resolved_at: new Date().toISOString() })
        .eq('id', row.id),
      markApnsLogFailed(supabase, row.notification_log_id, {
        errorCode: 'retry_unsendable',
        errorReason: 'Missing notification content or device token on retry',
        retryCount: row.attempt_number,
      }),
    ]);
    return 'exhausted';
  }

  const result = await sendCapturePush({
    token,
    environment,
    payloadId: row.payload_id,
    title: notification.title,
    body: notification.body,
    notificationType: notification.type,
  });

  if (result.ok) {
    await Promise.all([
      supabase
        .from('processed_captures')
        .update({ apns_push_sent_at: new Date().toISOString(), apns_push_error: null })
        .eq('install_id_hash', row.install_id_hash)
        .eq('payload_id', row.payload_id),
      markApnsLogSent(supabase, row.notification_log_id, result.apnsId),
      supabase
        .from('notification_retry_queue')
        .update({ resolved_at: new Date().toISOString() })
        .eq('id', row.id),
    ]);
    console.log(JSON.stringify({
      event: 'notification_sent',
      notificationLogId: row.notification_log_id,
      channel: 'apns',
      attempt: row.attempt_number + 1,
    }));
    return 'sent';
  }

  const nextAttemptNumber = row.attempt_number + 1;
  const stillTransient = isTransientApnsFailure(result.httpStatus, result.errorCode);
  const exhausted = !stillTransient || nextAttemptNumber >= row.max_attempts;

  await Promise.all([
    supabase
      .from('processed_captures')
      .update({ apns_push_error: result.reason })
      .eq('install_id_hash', row.install_id_hash)
      .eq('payload_id', row.payload_id),
    markApnsLogFailed(supabase, row.notification_log_id, {
      errorCode: result.errorCode,
      errorReason: result.reason,
      retryCount: nextAttemptNumber,
    }),
    exhausted
      ? supabase
        .from('notification_retry_queue')
        .update({
          attempt_number: nextAttemptNumber,
          last_error_code: result.errorCode,
          resolved_at: new Date().toISOString(),
        })
        .eq('id', row.id)
      : supabase
        .from('notification_retry_queue')
        .update({
          attempt_number: nextAttemptNumber,
          last_error_code: result.errorCode,
          next_attempt_at: new Date(Date.now() + nextRetryDelayMs(nextAttemptNumber)).toISOString(),
        })
        .eq('id', row.id),
  ]);

  console.warn(JSON.stringify({
    event: exhausted ? 'notification_retry_exhausted' : 'notification_retry_scheduled',
    notificationLogId: row.notification_log_id,
    attempt: nextAttemptNumber,
    errorCode: result.errorCode,
  }));
  return exhausted ? 'exhausted' : 'retrying';
}
