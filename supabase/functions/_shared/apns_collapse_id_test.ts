import { assertEquals, assertNotEquals } from 'jsr:@std/assert@1';
import { buildApnsCollapseId } from './apns_collapse_id.ts';

const encoder = new TextEncoder();

Deno.test('collapse-id is never more than 64 UTF-8 bytes', async () => {
  const samples = [
    '56e65066ae0f8355e51ab618b04cd4d768ca8056855b8a4461a1a78ea1c720cd', // real 64-char SHA-256 payloadId
    'codex_diagnose_ai_plain_transfer_ar_1783241038643', // real-world diagnostic-style payloadId
    'smoke_test_hardening_1',
    '',
    'a'.repeat(500), // pathological, far longer than any real payloadId
  ];
  for (const payloadId of samples) {
    const collapseId = await buildApnsCollapseId(payloadId);
    const byteLength = encoder.encode(collapseId).length;
    if (byteLength > 64) {
      throw new Error(`payloadId=${payloadId.slice(0, 20)}... produced ${byteLength} bytes`);
    }
  }
});

Deno.test('collapse-id is deterministic: same payloadId => same collapse-id', async () => {
  const payloadId = '56e65066ae0f8355e51ab618b04cd4d768ca8056855b8a4461a1a78ea1c720cd';
  const first = await buildApnsCollapseId(payloadId);
  const second = await buildApnsCollapseId(payloadId);
  assertEquals(first, second);
});

Deno.test(
  'different payloadIds produce different collapse-ids, including ones sharing a long common prefix',
  async () => {
    // Two real-world-shaped diagnostic payloadIds that share everything
    // except a trailing timestamp — a naive prefix-truncation of the
    // original payloadId would have collapsed these into the same id.
    const a = await buildApnsCollapseId('codex_diagnose_ai_plain_transfer_ar_1783241038643');
    const b = await buildApnsCollapseId('codex_diagnose_ai_plain_transfer_ar_1783241038999');
    assertNotEquals(a, b);

    // Two SHA-256-shaped payloadIds differing only in the last character.
    const c = await buildApnsCollapseId(
      '56e65066ae0f8355e51ab618b04cd4d768ca8056855b8a4461a1a78ea1c720cd',
    );
    const d = await buildApnsCollapseId(
      '56e65066ae0f8355e51ab618b04cd4d768ca8056855b8a4461a1a78ea1c720ce',
    );
    assertNotEquals(c, d);
  },
);

Deno.test('collapse-id is ASCII-only (hex + fixed prefix)', async () => {
  const collapseId = await buildApnsCollapseId('أي نص عربي كاختبار');
  assertEquals(/^qc-[0-9a-f]+$/.test(collapseId), true);
});

Deno.test('1000 distinct payloadIds produce 1000 distinct collapse-ids (negligible collision risk)', async () => {
  const seen = new Set<string>();
  for (let i = 0; i < 1000; i++) {
    const collapseId = await buildApnsCollapseId(`payload-${i}`);
    seen.add(collapseId);
  }
  assertEquals(seen.size, 1000);
});
