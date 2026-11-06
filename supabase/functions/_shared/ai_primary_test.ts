import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { checkPrimaryAmount, runPrimaryAi } from './ai_primary.ts';

const qnb = 'QNB: Purchase of EGP 250.00 at CARREFOUR. Available balance EGP 4750.00.';
const candidate = { is_transaction: true, amount: 250, amount_text: '250.00',
  currency: 'EGP', type: 'payment', direction: 'debit', category: 'groceries' };
const modelReply = (value: unknown) =>
  new Response(JSON.stringify({ candidates: [{ content: { parts: [{ text: JSON.stringify(value) }] } }] }));

Deno.test('QNB: AI repairs an extracted balance and checks consent before its next call', async () => {
  const requests: string[] = [];
  let consentChecks = 0;
  const reply = await runPrimaryAi({
    key: 'test', model: 'gemini-3.8-flash', prompt: qnb,
    beforeAttempt: () => Promise.resolve(++consentChecks > 0),
    validate: (value) => checkPrimaryAmount(value, qnb),
    sleep: () => Promise.resolve(),
    fetcher: (_url, init) => {
      requests.push(String(init?.body));
      return Promise.resolve(modelReply(requests.length === 1
        ? { ...candidate, amount: 4750, amount_text: '4750.00' } : candidate));
    },
  });
  assertEquals(reply, { ok: true, value: candidate, attempts: 2 });
  assertEquals(consentChecks, 2);
  assertEquals(requests[1].includes('transaction_amount_not_balance'), true);
});

Deno.test('transient AI failure stops before re-sending after consent changes', async () => {
  let checks = 0;
  let calls = 0;
  const reply = await runPrimaryAi({
    key: 'test', model: 'gemini-3.8-flash', prompt: qnb,
    beforeAttempt: () => Promise.resolve(++checks === 1),
    validate: () => null, sleep: () => Promise.resolve(),
    fetcher: () => { calls++; return Promise.resolve(new Response('', { status: 503 })); },
  });
  assertEquals(reply, { ok: false, reason: 'denied', attempts: 1 });
  assertEquals(calls, 1);
});
