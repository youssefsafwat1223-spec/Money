// Bounded APNs retry policy shared by process-ios-sms (schedules the first
// retry) and process-notification-retries (drains the queue). See
// docs/NOTIFICATION_PIPELINE_AUDIT.md Phase 1, item 8 — retries never sleep
// inside a request; they're durable rows processed by a separate dispatch.

export const MAX_NOTIFICATION_RETRY_ATTEMPTS = 5;

const TRANSIENT_HTTP_STATUSES = new Set([429, 500, 503]);
const TRANSIENT_ERROR_CODES = new Set(['timeout', 'network_exception']);

/** httpStatus is null for exception-shaped failures (timeout/network). */
export function isTransientApnsFailure(
  httpStatus: number | null,
  errorCode: string,
): boolean {
  if (httpStatus !== null) return TRANSIENT_HTTP_STATUSES.has(httpStatus);
  return TRANSIENT_ERROR_CODES.has(errorCode);
}

/** Exponential backoff capped at 30 minutes: 1m, 2m, 4m, 8m, 16m (capped 30m). */
export function nextRetryDelayMs(attemptNumber: number): number {
  const minutes = Math.min(2 ** (attemptNumber - 1), 30);
  return minutes * 60_000;
}
