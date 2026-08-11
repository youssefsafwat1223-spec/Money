import { assert, assertEquals, assertNotEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { amountFromText, withValidatedModelAmountText } from './money.ts';

Deno.test('parse-sms fallback validates currency scale without rounding exact text', () => {
  assertEquals(amountFromText('debited JPY 19'), { amount: 19, amount_text: '19', currency: 'JPY' });
  assertEquals(amountFromText('debited JPY 19.0'), { amount: 19, currency: 'JPY' });
  assertEquals(amountFromText('debited EGP 19.99'), { amount: 19.99, amount_text: '19.99', currency: 'EGP' });
  assertEquals(amountFromText('debited USD 19.99'), { amount: 19.99, amount_text: '19.99', currency: 'USD' });
  assertEquals(amountFromText('debited KWD 1.005'), { amount: 1.005, amount_text: '1.005', currency: 'KWD' });

  const overScale = amountFromText('debited EGP 1.005');
  assertEquals(overScale?.amount, 1.005);
  assertEquals(overScale?.amount_text, undefined);
});

Deno.test('parse-sms fallback preserves IEEE-754-damaged lexical identity independently', () => {
  const token = '9007199254740993';
  const parsed = amountFromText(`debited USD ${token}`);
  assert(parsed);
  assertEquals(parsed.amount, Number(token));
  assertEquals(parsed.amount_text, token);
  assertNotEquals(parsed.amount.toString(), token);
});

Deno.test('parse-sms model contract emits only validated independent string text', () => {
  const token = '9007199254740993';
  const response = withValidatedModelAmountText({
    amount: Number(token),
    amount_text: token,
    currency: 'USD',
  });
  assertEquals(response.amount, Number(token));
  assertEquals(response.amount_text, token);

  const oldNumericOnly = withValidatedModelAmountText({ amount: 19.99, currency: 'EGP' });
  assertEquals(oldNumericOnly.amount, 19.99);
  assertEquals(Object.hasOwn(oldNumericOnly, 'amount_text'), false);

  const overScale = withValidatedModelAmountText({ amount: 1.005, amount_text: '1.005', currency: 'EGP' });
  assertEquals(overScale.amount, 1.005);
  assertEquals(Object.hasOwn(overScale, 'amount_text'), false);

  const exponent = withValidatedModelAmountText({ amount: 1000, amount_text: '1e3', currency: 'USD' });
  assertEquals(exponent.amount, 1000);
  assertEquals(Object.hasOwn(exponent, 'amount_text'), false);
});

Deno.test('parse-sms fallback rejects ambiguous grouping for exact text but retains legacy numeric', () => {
  const parsed = amountFromText('debited USD 1,2');
  assertEquals(parsed?.amount, 12);
  assertEquals(parsed?.amount_text, undefined);
});
