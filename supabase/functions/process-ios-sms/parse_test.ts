import { assert, assertEquals, assertNotEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { deterministicParse, isResolved, parseSms } from './parse.ts';

const RECEIVED = '2026-09-07T19:30:00.000Z';

const RESOLVED_SMS = 'Purchase of EGP 250.00 at CARREFOUR with card ending 1234 on 2026-09-07';
const IGNORED_SMS = 'Your OTP is 123456 for EGP 10.00 purchase';
// Clean card/ATM SMS: amount+currency+direction, NO merchant -> RESOLVED (merchant optional)
const CLEAN_SMS = [
  'Debited SAR 50.00 from card ending 1234',
  'ATM withdrawal of SAR 500.00 card 1234',
  'تم خصم 50.00 ر.س من بطاقتك 1234',
];
// amount+currency, direction unknown, no merchant -> unresolved, HYBRID
const HYBRID_SMS = 'EGP 99.50 ZARA online';
// direction unknown, no merchant -> unresolved, HYBRID
const HYBRID_NO_DIR_SMS = 'Your card 1234 was used for EGP 99.50';
// no amount/currency -> unresolved, AI-only ($ is not a deterministic currency)
const AI_ONLY_SMS = 'Purchase $20.00 at SHOP';

type Stub = { calls: number; restore: () => void };

function stubGemini(candidate: Record<string, unknown> | null, status = 200): Stub {
  const original = globalThis.fetch;
  const previousKey = Deno.env.get('GEMINI_API_KEY');
  Deno.env.set('GEMINI_API_KEY', 'test-key');
  const stub: Stub = {
    calls: 0,
    restore: () => {
      globalThis.fetch = original;
      if (previousKey == null) Deno.env.delete('GEMINI_API_KEY');
      else Deno.env.set('GEMINI_API_KEY', previousKey);
    },
  };
  globalThis.fetch = (() => {
    stub.calls++;
    const body = candidate == null
      ? {}
      : { candidates: [{ content: { parts: [{ text: JSON.stringify(candidate) }] } }] };
    return Promise.resolve(new Response(JSON.stringify(body), { status }));
  }) as typeof fetch;
  return stub;
}

async function run(text: string, allowAi: boolean, candidate: Record<string, unknown> | null) {
  const stub = stubGemini(candidate);
  try {
    const outcome = await parseSms({
      text,
      rawText: text,
      sender: 'BANK',
      receivedAt: RECEIVED,
      tzOffsetMinutes: 180,
      locale: 'en',
      allowAi,
    });
    return { ...outcome, calls: stub.calls };
  } finally {
    stub.restore();
  }
}

const GOOD_AI = {
  amount: 20,
  amount_text: '20.00',
  currency: 'USD',
  merchant: 'SHOP',
  type: 'payment',
  direction: 'debit',
};

Deno.test('deterministic fixtures have the intended shape', () => {
  assert(isResolved(deterministicParse(RESOLVED_SMS, RECEIVED, 180)));
  assert(!isResolved(deterministicParse(HYBRID_SMS, RECEIVED, 180)));
  assert(!isResolved(deterministicParse(HYBRID_NO_DIR_SMS, RECEIVED, 180)));
  const aiOnly = deterministicParse(AI_ONLY_SMS, RECEIVED, 180);
  assertEquals([aiOnly.amount, aiOnly.currency], [undefined, undefined]);
});

Deno.test('RESOLVED => zero AI calls + accepted (even with AI allowed)', async () => {
  const r = await run(RESOLVED_SMS, true, GOOD_AI);
  assertEquals(r.calls, 0);
  assertEquals(r.accepted, true);
  assertEquals(r.parsed.parserSource, 'deterministic');
  assertEquals(r.parsed.amount, 250);
});

Deno.test('clean card/ATM SMS (no merchant) => RESOLVED: zero AI calls + accepted, AI allowed or not', async () => {
  for (const text of CLEAN_SMS) {
    for (const allowAi of [true, false]) {
      const r = await run(text, allowAi, GOOD_AI);
      assertEquals(r.calls, 0, text);
      assertEquals(r.accepted, true, text);
      assertEquals(r.parsed.parserSource, 'deterministic');
      assertEquals(r.parsed.direction, 'debit');
      assertEquals(r.parsed.merchant, undefined);
    }
  }
});

Deno.test('direction unknown => still UNRESOLVED: goes to AI when allowed, rejected otherwise', async () => {
  const withAi = await run(HYBRID_NO_DIR_SMS, true, GOOD_AI);
  assertEquals(withAi.calls, 1);
  const noAi = await run(HYBRID_NO_DIR_SMS, false, GOOD_AI);
  assertEquals([noAi.calls, noAi.accepted], [0, false]);
});

Deno.test('IGNORED => zero AI calls + rejected, even with AI allowed and a transaction-shaped AI answer', async () => {
  const r = await run(IGNORED_SMS, true, { amount: 10, amount_text: '10.00', currency: 'EGP', type: 'payment' });
  assertEquals(r.calls, 0);
  assertEquals(r.accepted, false);
  assertEquals(r.parsed.amount, undefined);
  assertEquals(r.parsed.confidence, 0);
});

Deno.test('UNRESOLVED + AI allowed => exactly ONE AI call', async () => {
  for (const text of [HYBRID_SMS, HYBRID_NO_DIR_SMS, AI_ONLY_SMS]) {
    const r = await run(text, true, GOOD_AI);
    assertEquals(r.calls, 1, text);
  }
});

Deno.test('UNRESOLVED + AI not allowed => zero AI calls + rejected', async () => {
  for (const text of [HYBRID_SMS, HYBRID_NO_DIR_SMS, AI_ONLY_SMS]) {
    const r = await run(text, false, GOOD_AI);
    assertEquals(r.calls, 0, text);
    assertEquals(r.accepted, false, text);
  }
});

Deno.test('AI-only validator PASS => accepted; FAIL => rejected', async () => {
  const pass = await run(AI_ONLY_SMS, true, GOOD_AI);
  assertEquals(pass.accepted, true);
  assertEquals(pass.parsed.amount, 20);
  assertEquals(pass.parsed.amount_text, '20.00');
  assertEquals(pass.parsed.currency, 'USD');
  assertEquals(pass.parsed.parserSource, 'ai_hybrid');

  const ungroundedAmount = await run(AI_ONLY_SMS, true, { ...GOOD_AI, amount: 21, amount_text: '21.00' });
  assertEquals(ungroundedAmount.accepted, false);
  const ungroundedCurrency = await run(AI_ONLY_SMS, true, { ...GOOD_AI, currency: 'SAR' });
  assertEquals(ungroundedCurrency.accepted, false);
  const noAmountText = await run(AI_ONLY_SMS, true, { amount: 20, currency: 'USD' });
  assertEquals(noAmountText.accepted, false);
  const contradicts = await run('Deposit $20.00 from SHOP', true, { ...GOOD_AI, type: 'payment' });
  assertEquals(contradicts.accepted, false);
});

Deno.test('AI unavailable / not a transaction / HTTP failure => rejected, still one call', async () => {
  const none = await run(AI_ONLY_SMS, true, { is_transaction: false });
  assertEquals([none.calls, none.accepted], [1, false]);
  const stub = stubGemini({ amount: 20 }, 500);
  try {
    const r = await parseSms({
      text: AI_ONLY_SMS,
      rawText: AI_ONLY_SMS,
      sender: '',
      receivedAt: RECEIVED,
      tzOffsetMinutes: null,
      locale: '',
      allowAi: true,
    });
    assertEquals([stub.calls, r.accepted], [1, false]);
  } finally {
    stub.restore();
  }
});

Deno.test('AI confidence (0.01 vs 0.99, top-level or absent) never changes the outcome', async () => {
  for (const text of [HYBRID_SMS, AI_ONLY_SMS]) {
    const cand = text === AI_ONLY_SMS
      ? GOOD_AI
      : { amount: 99.5, amount_text: '99.50', currency: 'EGP', merchant: 'ZARA', direction: 'debit' };
    const low = await run(text, true, { ...cand, confidence: 0.01 });
    const high = await run(text, true, { ...cand, confidence: 0.99 });
    const none = await run(text, true, cand);
    assertEquals(low.accepted, true);
    assertEquals(low.parsed, high.parsed);
    assertEquals(low.parsed, none.parsed);
  }
  // A failing candidate stays failing at confidence 0.99.
  const bad = await run(AI_ONLY_SMS, true, { ...GOOD_AI, amount: 21, amount_text: '21.00', confidence: 0.99 });
  assertEquals(bad.accepted, false);
});

Deno.test('contradictory AI amount/currency never replace deterministic values', async () => {
  for (
    const cand of [
      { amount: 77, amount_text: '77.00', currency: 'EGP', merchant: 'ZARA' },
      { amount: 99.5, amount_text: '99.50', currency: 'SAR', merchant: 'ZARA' },
    ]
  ) {
    const r = await run(HYBRID_SMS, true, cand);
    assertEquals(r.accepted, false);
    assertEquals(r.parsed.amount, 99.5);
    assertEquals(r.parsed.currency, 'EGP');
    assertEquals(r.parsed.parserSource, 'deterministic');
  }
});

Deno.test('contradictory AI merchant never replaces a deterministic merchant', async () => {
  // Resolved never reaches the AI; to exercise the merge use a parse that has a
  // merchant but lacks direction.
  const text = 'Transaction of EGP 60.00 at CARREFOUR';
  const det = deterministicParse(text, RECEIVED, 180);
  assertEquals(det.merchant, 'CARREFOUR');
  assertEquals(det.direction, 'unknown');
  const r = await run(text, true, {
    amount: 60,
    amount_text: '60.00',
    currency: 'EGP',
    merchant: 'AMAZON',
    type: 'payment',
    direction: 'debit',
  });
  assertEquals(r.calls, 1);
  assertEquals(r.accepted, true);
  assertEquals(r.parsed.merchant, 'CARREFOUR');
});

Deno.test('hybrid fills ONLY missing grounded fields', async () => {
  // merchant: grounded fills; ungrounded is dropped (not a rejection).
  const grounded = await run(HYBRID_SMS, true, {
    amount: 99.5,
    amount_text: '99.50',
    currency: 'EGP',
    merchant: 'ZARA',
    direction: 'debit',
  });
  assertEquals(grounded.accepted, true);
  assertEquals(grounded.parsed.merchant, 'ZARA');
  assertEquals(grounded.parsed.amount, 99.5);
  assertEquals(grounded.parsed.direction, 'debit'); // filled: deterministic had none
  const ungrounded = await run(HYBRID_SMS, true, {
    amount: 99.5,
    amount_text: '99.50',
    currency: 'EGP',
    merchant: 'AMAZON',
    direction: 'debit',
  });
  assertEquals(ungrounded.accepted, true);
  assertEquals(ungrounded.parsed.merchant, undefined);

  // direction: filled only when deterministic had none, and never against the wording.
  const dirFill = await run(HYBRID_NO_DIR_SMS, true, {
    amount: 99.5,
    amount_text: '99.50',
    currency: 'EGP',
    merchant: 'ZARA',
    direction: 'debit',
    type: 'payment',
  });
  assertEquals(dirFill.accepted, true);
  assertEquals(dirFill.parsed.direction, 'debit');
  assertEquals(dirFill.parsed.merchant, undefined); // ZARA not in this text
  assertEquals(dirFill.parsed.last4, '1234'); // deterministic, untouched
  // last4: grounded fills, ungrounded dropped.
  const last4Text = 'EGP 99.50 ZARA online ref 4321';
  const l4 = await run(last4Text, true, {
    amount: 99.5,
    amount_text: '99.50',
    currency: 'EGP',
    merchant: 'ZARA',
    last4: '4321',
    direction: 'debit',
  });
  assertEquals(l4.parsed.last4, '4321');
  const l4bad = await run(last4Text, true, {
    amount: 99.5,
    amount_text: '99.50',
    currency: 'EGP',
    merchant: 'ZARA',
    last4: '9999',
    direction: 'debit',
  });
  assertEquals(l4bad.parsed.last4, undefined);

  // A hybrid candidate with no resolvable direction is NOT accepted.
  const noDir = await run(HYBRID_SMS, true, {
    amount: 99.5,
    amount_text: '99.50',
    currency: 'EGP',
    merchant: 'ZARA',
  });
  assertEquals(noDir.accepted, false);
  const transferOnly = await run(HYBRID_SMS, true, {
    amount: 99.5,
    amount_text: '99.50',
    currency: 'EGP',
    type: 'transfer',
  });
  assertEquals(transferOnly.accepted, false);
});

Deno.test('informational confidence: formula over final fields, AI-filled direction not counted', async () => {
  const r = await run(HYBRID_NO_DIR_SMS, true, {
    amount: 99.5,
    amount_text: '99.50',
    currency: 'EGP',
    direction: 'debit',
    type: 'payment',
  });
  assertEquals(r.parsed.direction, 'debit');
  // 0.55 money + 0.05 last4; no merchant; direction was AI-filled so +0 .
  assertEquals(Math.round((r.parsed.confidence ?? 0) * 100), 60);
});

Deno.test('AI date outside the window is dropped, inside is kept', async () => {
  const inside = await run(AI_ONLY_SMS, true, { ...GOOD_AI, occurredAt: '2026-09-06T10:00:00Z' });
  assertEquals(inside.parsed.comparisonTimestampSource, 'sms_body');
  const outside = await run(AI_ONLY_SMS, true, { ...GOOD_AI, occurredAt: '2026-01-01T10:00:00Z' });
  assertEquals(outside.accepted, true);
  assertEquals(outside.parsed.comparisonTimestampSource, 'received_at');
  assertNotEquals(outside.parsed.comparisonTimestamp, '2026-01-01T10:00:00.000Z');
});
