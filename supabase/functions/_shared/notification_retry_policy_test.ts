import { assertEquals } from 'jsr:@std/assert@1';
import {
  isTransientApnsFailure,
  MAX_NOTIFICATION_RETRY_ATTEMPTS,
  nextRetryDelayMs,
} from './notification_retry_policy.ts';

Deno.test('transient HTTP statuses (429/500/503) are retried', () => {
  assertEquals(isTransientApnsFailure(429, 'TooManyRequests'), true);
  assertEquals(isTransientApnsFailure(500, 'InternalServerError'), true);
  assertEquals(isTransientApnsFailure(503, 'ServiceUnavailable'), true);
});

Deno.test('transient network-shaped exceptions (no HTTP status) are retried', () => {
  assertEquals(isTransientApnsFailure(null, 'timeout'), true);
  assertEquals(isTransientApnsFailure(null, 'network_exception'), true);
});

Deno.test('permanent APNs reason codes are never retried', () => {
  // These arrive with a 400/410-shaped status, which is not in the
  // transient set — see docs/NOTIFICATION_PIPELINE_AUDIT.md Phase 1, item 8.
  assertEquals(isTransientApnsFailure(400, 'BadDeviceToken'), false);
  assertEquals(isTransientApnsFailure(400, 'DeviceTokenNotForTopic'), false);
  assertEquals(isTransientApnsFailure(400, 'TopicDisallowed'), false);
  assertEquals(isTransientApnsFailure(400, 'BadTopic'), false);
  assertEquals(isTransientApnsFailure(400, 'PayloadEmpty'), false);
  assertEquals(isTransientApnsFailure(413, 'PayloadTooLarge'), false);
});

Deno.test('a static configuration failure is not retried', () => {
  assertEquals(isTransientApnsFailure(null, 'not_configured'), false);
});

Deno.test('unrecognized non-transient HTTP statuses are not retried', () => {
  assertEquals(isTransientApnsFailure(401, 'Unauthorized'), false);
  assertEquals(isTransientApnsFailure(403, 'Forbidden'), false);
  assertEquals(isTransientApnsFailure(404, 'NotFound'), false);
});

Deno.test('backoff doubles per attempt and is capped at 30 minutes', () => {
  assertEquals(nextRetryDelayMs(1), 60_000);
  assertEquals(nextRetryDelayMs(2), 120_000);
  assertEquals(nextRetryDelayMs(3), 240_000);
  assertEquals(nextRetryDelayMs(4), 480_000);
  assertEquals(nextRetryDelayMs(5), 960_000);
  // 2^5 = 32 minutes would exceed the cap.
  assertEquals(nextRetryDelayMs(6), 30 * 60_000);
  assertEquals(nextRetryDelayMs(20), 30 * 60_000);
});

Deno.test('max attempts constant matches the documented bound', () => {
  assertEquals(MAX_NOTIFICATION_RETRY_ATTEMPTS, 5);
});
