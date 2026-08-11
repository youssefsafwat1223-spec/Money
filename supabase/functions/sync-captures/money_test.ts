import { assertEquals, assertNotEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { capturesForResponse } from './money.ts';

Deno.test('sync-captures preserves exact stored text independently of compatibility numbers', () => {
  const token = '9007199254740993';
  const wire = JSON.parse(JSON.stringify(capturesForResponse([{
    payload_id: 'p1',
    parsed: {
      amount: 1,
      amount_text: token,
      currency: 'USD',
      balance_after: null,
      balance_after_text: null,
      foreign_amount: 7,
      foreign_amount_text: '1.005',
      foreign_currency: 'KWD',
    },
  }]))) as Array<Record<string, unknown>>;
  const [capture] = wire;
  const parsed = capture.parsed as Record<string, unknown>;

  assertEquals(parsed.amount, Number(token));
  assertEquals(parsed.amount_text, token);
  assertNotEquals((parsed.amount as number).toString(), token);
  assertEquals(parsed.balance_after, null);
  assertEquals(parsed.balance_after_text, null);
  assertEquals(parsed.foreign_amount, 1.005);
  assertEquals(parsed.foreign_amount_text, '1.005');
  assertEquals(parsed.foreign_currency, 'KWD');
});

Deno.test('sync-captures does not invent text for historical numeric-only rows', () => {
  const [capture] = capturesForResponse([{
    payload_id: 'legacy',
    parsed: { amount: 19.99, currency: 'EGP' },
  }]) as Array<Record<string, unknown>>;
  const parsed = capture.parsed as Record<string, unknown>;
  assertEquals(parsed.amount, 19.99);
  assertEquals(Object.hasOwn(parsed, 'amount_text'), false);
});

Deno.test('sync-captures omits invalid exact text without changing legacy numeric fields', () => {
  const [capture] = capturesForResponse([{
    payload_id: 'over-scale',
    parsed: {
      amount: 1.005,
      amount_text: '1.005',
      currency: 'EGP',
      foreign_amount: 12.34,
      foreign_amount_text: '12.34',
    },
  }]) as Array<Record<string, unknown>>;
  const parsed = capture.parsed as Record<string, unknown>;
  assertEquals(parsed.amount, 1.005);
  assertEquals(parsed.foreign_amount, 12.34);
  assertEquals(Object.hasOwn(parsed, 'amount_text'), false);
  assertEquals(Object.hasOwn(parsed, 'foreign_amount_text'), false);
});
