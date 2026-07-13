import { assertEquals, assertNotEquals } from 'jsr:@std/assert@1';
import {
  fingerprintTimeKeys,
  RECEIVED_AT_BUCKET_MS,
} from './capture_fingerprint.ts';

Deno.test('sms_body timestamps stay exact — no tolerance window', () => {
  const keys = fingerprintTimeKeys('2026-07-13T10:00:00.000Z', 'sms_body');
  assertEquals(keys, ['2026-07-13T10:00:00.000Z']);
});

Deno.test('received_at produces current + previous bucket keys', () => {
  const iso = '2026-07-13T10:00:00.000Z';
  const bucket = Math.floor(new Date(iso).getTime() / RECEIVED_AT_BUCKET_MS);
  assertEquals(fingerprintTimeKeys(iso, 'received_at'), [
    `rb:${bucket}`,
    `rb:${bucket - 1}`,
  ]);
});

Deno.test('shortcut re-run seconds later matches the original fingerprint', () => {
  const first = fingerprintTimeKeys('2026-07-13T10:04:30.000Z', 'received_at');
  const rerun = fingerprintTimeKeys('2026-07-13T10:05:10.000Z', 'received_at');
  // The stored key is the re-run's first candidate OR its previous bucket;
  // the original's stored key (first candidate) must appear among the
  // re-run's candidates even across a bucket boundary.
  assertEquals(rerun.includes(first[0]), true);
});

Deno.test('re-run across a bucket boundary still matches via previous bucket', () => {
  const first = fingerprintTimeKeys('2026-07-13T10:09:59.000Z', 'received_at');
  const rerun = fingerprintTimeKeys('2026-07-13T10:10:05.000Z', 'received_at');
  assertNotEquals(first[0], rerun[0]);
  assertEquals(rerun[1], first[0]);
});

Deno.test('distinct receipts well apart never share a candidate key', () => {
  const a = fingerprintTimeKeys('2026-07-13T10:00:00.000Z', 'received_at');
  const b = fingerprintTimeKeys('2026-07-13T11:00:00.000Z', 'received_at');
  assertEquals(a.some((key) => b.includes(key)), false);
});

Deno.test('unparseable received_at falls back to the exact string', () => {
  assertEquals(fingerprintTimeKeys('not-a-date', 'received_at'), ['not-a-date']);
});
