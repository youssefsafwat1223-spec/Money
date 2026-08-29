import { serviceClient } from '../_shared/capture_auth.ts';
import { sendCapturePush } from '../_shared/apns.ts';
import { markApnsLogFailed, markApnsLogSent } from '../_shared/notification_logs.ts';
import { isTransientApnsFailure, nextRetryDelayMs } from '../_shared/notification_retry_policy.ts';

type NotificationPayload = {
  title: string;
  body: string;
  type: 'new_transaction' | 'needs_review' | 'suspicious_duplicate' | 'received';
};

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
  sendPush: typeof sendCapturePush = sendCapturePush,
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
      .select('apns_token,apns_environment,revoked_at')
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

  // A retry must re-check the mutable credential state. A queued notification
  // is never authority to deliver after device revocation, so drop it without
  // calling APNs even when the stored token remains present.
  if (device?.revoked_at != null) {
    await Promise.all([
      supabase
        .from('notification_retry_queue')
        .update({ resolved_at: new Date().toISOString() })
        .eq('id', row.id),
      markApnsLogFailed(supabase, row.notification_log_id, {
        errorCode: 'credential_revoked',
        errorReason: 'Device credential was revoked before notification retry',
        retryCount: row.attempt_number,
      }),
    ]);
    return 'exhausted';
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

  const result = await sendPush({
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
