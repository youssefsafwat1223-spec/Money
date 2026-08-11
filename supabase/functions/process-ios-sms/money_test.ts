import { assertEquals, assertNotEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { canonicalMoneyText, withValidatedExactMoneyText } from '../_shared/money_text.ts';
import { extractCaptureAmount, withValidatedModelAmountText } from './money.ts';

const patterns = ['(?:amount|amt)[\\s:]*([0-9][0-9,]*(?:\\.[0-9]+)?)'];

Deno.test('process-ios-sms preserves clean bank-message tokens by currency scale', () => {
  assertEquals(extractCaptureAmount('amount JPY 19', ['JPY\\s*([0-9][0-9,]*(?:\\.[0-9]+)?)'], 'JPY'), {
    amount: 19,
    amount_text: '19',
  });
  assertEquals(extractCaptureAmount('amount: 19.99', patterns, 'EGP'), { amount: 19.99, amount_text: '19.99' });
  assertEquals(extractCaptureAmount('amount: 19.99', patterns, 'USD'), { amount: 19.99, amount_text: '19.99' });
  assertEquals(extractCaptureAmount('amount: 1.005', patterns, 'KWD'), { amount: 1.005, amount_text: '1.005' });
  assertEquals(extractCaptureAmount('amount: 1.005', patterns, 'EGP'), { amount: 1.005 });
});

Deno.test('process-ios-sms exact token is independent of lossy compatibility number', () => {
  const token = '9007199254740993';
  const parsed = extractCaptureAmount(`amount: ${token}`, patterns, 'USD');
  assertEquals(parsed.amount, Number(token));
  assertEquals(parsed.amount_text, token);
  assertNotEquals(parsed.amount?.toString(), token);
});

Deno.test('process-ios-sms accepts negative exact balance where the field contract allows it', () => {
  assertEquals(canonicalMoneyText('-19.99', 'USD', { allowNegative: true }), '-19.99');
  assertEquals(canonicalMoneyText('-19.99', 'USD'), null);
  assertEquals(
    withValidatedExactMoneyText({ currency: 'USD', balance_after: -19.99, balance_after_text: '-19.99' }),
    { currency: 'USD', balance_after: -19.99, balance_after_text: '-19.99' },
  );
});

Deno.test('process-ios-sms model contract never derives text from a JSON number', () => {
  const numericOnly = withValidatedModelAmountText({ amount: 19.99, currency: 'USD' });
  assertEquals(numericOnly.amount, 19.99);
  assertEquals(Object.hasOwn(numericOnly, 'amount_text'), false);

  const valid = withValidatedModelAmountText({ amount: 20, amount_text: '19.99', currency: 'USD' });
  assertEquals(valid, { amount: 19.99, amount_text: '19.99', currency: 'USD' });
});

Deno.test('process-ios-sms model amount_text stays authoritative beyond IEEE-754 precision', () => {
  const token = '9007199254740993';
  const valid = withValidatedModelAmountText({ amount: 7, amount_text: token, currency: 'USD' });
  assertEquals(valid.amount_text, token);
  assertEquals(valid.amount, Number(token));
  assertNotEquals((valid.amount as number).toString(), token);
});
