// Capture-push hygiene shared by process-ios-sms (first attempt) and
// process-notification-retries (retries). CAP-3, manifest §4.8 / Q3.
//
// * The APNs alert for a capture is GENERIC: no amount, merchant, card, sender or
//   SMS text ever leaves for Apple (Q3). The detailed result stays in the relay row
//   and is pulled by the app after the tap.
// * A dead token is cleared by compare-and-swap, so a token the app re-registered in
//   the meantime is never wiped.
// * A retry is enqueued at most once per notification (UNIQUE(notification_log_id)).

import { serviceClient } from './capture_auth.ts';

type SupabaseClientLike = ReturnType<typeof serviceClient>;

// Q3 wording, verbatim from the manifest. Title is omitted (iOS shows the app name).
export const GENERIC_CAPTURE_PUSH = { title: '', body: 'New transaction captured' } as const;

const DEAD_TOKEN_CODES = new Set(['BadDeviceToken', 'Unregistered', 'ExpiredToken']);

export function isDeadApnsToken(result: { httpStatus: number | null; errorCode: string }): boolean {
  return result.httpStatus === 410 || DEAD_TOKEN_CODES.has(result.errorCode);
}

/** Nulls the token only where it still equals the failing one. */
export async function clearDeadApnsToken(
  supabase: SupabaseClientLike,
  installIdHash: string,
  failingToken: string,
): Promise<void> {
  await supabase
    .from('capture_devices')
    .update({ apns_token: null, apns_environment: null, token_updated_at: new Date().toISOString() })
    .eq('install_id_hash', installIdHash)
    .eq('apns_token', failingToken);
}

/** Idempotent: a second enqueue for the same notification is a no-op. */
export async function enqueueNotificationRetry(
  supabase: SupabaseClientLike,
  row: {
    notificationLogId: string;
    installIdHash: string;
    payloadId: string;
    maxAttempts: number;
    nextAttemptAt: string;
    lastErrorCode: string;
  },
): Promise<void> {
  await supabase.from('notification_retry_queue').upsert({
    notification_log_id: row.notificationLogId,
    install_id_hash: row.installIdHash,
    payload_id: row.payloadId,
    attempt_number: 1,
    max_attempts: row.maxAttempts,
    next_attempt_at: row.nextAttemptAt,
    last_error_code: row.lastErrorCode,
  }, { onConflict: 'notification_log_id', ignoreDuplicates: true });
}
