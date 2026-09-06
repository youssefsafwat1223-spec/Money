// The promotion contract. These drive the REAL validator.
import { assertEquals } from 'https://deno.land/std@0.208.0/testing/asserts.ts';
import {
  classify,
  evaluateRow,
  validateParser,
  type GoldenRow,
  type RuleUnderTest,
} from './parser_validation.ts';

// The production SNB rule, post-fix: currency required before the amount.
const SNB: RuleUnderTest = {
  id: 'rule-snb',
  sender_pattern: '^(SNB|AlAhli|Al Ahli)$',
  message_pattern:
    '[\\s\\S]*(?:شراء|دفع|Purchase|Payment)[\\s\\S]*?(?:SAR|ريال|ر\\.س)\\s*(?<amount>[0-9][0-9,]*(?:\\.[0-9]{1,3})?)[\\s\\S]*?(?:لدى|At)\\s*:?[ ]*(?<merchant>[^\\n]+)?',
  transaction_type: 'debit',
  extracted_fields: { amount: 'amount', currency: 'SAR', merchant: 'merchant', type: 'debit' },
};

function row(over: Partial<GoldenRow> = {}): GoldenRow {
  return {
    id: 'row-1',
    sender: 'SNB',
    message_text: 'عملية شراء\nبطاقة:مدى;****4521\nمبلغ:SAR 45.00\nلدى:NETFLIX',
    expected_type: 'debit',
    expected_amount: 45.0,
    expected_currency: 'SAR',
    expected_merchant: 'NETFLIX',
    ...over,
  };
}

Deno.test('a fully-specified positive row passes and records what it checked', () => {
  const r = evaluateRow(SNB, row());
  assertEquals(r.passed, true);
  assertEquals(r.applicability, 'positive');
  // Every claimed field was actually compared — the old validator checked only amount.
  assertEquals(r.checked_fields.sort(), ['amount', 'currency', 'merchant', 'type']);
});

Deno.test('a WRONG amount fails — the card-mask defect', () => {
  // The exact production failure: the rule captured the card suffix.
  const r = evaluateRow(SNB, row({ expected_amount: 4521 }));
  assertEquals(r.passed, false);
  assertEquals(r.failure_kind, 'amount_mismatch');
});

Deno.test('a wrong CURRENCY fails — never checked before', () => {
  const r = evaluateRow(SNB, row({ expected_currency: 'EGP' }));
  assertEquals(r.passed, false);
  assertEquals(r.failure_kind, 'currency_mismatch');
});

Deno.test('a wrong MERCHANT fails — never checked before', () => {
  const r = evaluateRow(SNB, row({ expected_merchant: 'SPOTIFY' }));
  assertEquals(r.passed, false);
  assertEquals(r.failure_kind, 'merchant_mismatch');
});

Deno.test('a wrong TYPE fails — never checked before', () => {
  // Same class as the rule would make it a positive; force a type claim clash.
  const credit: RuleUnderTest = { ...SNB, transaction_type: 'debit',
    extracted_fields: { ...SNB.extracted_fields, type: 'credit' } };
  const r = evaluateRow(credit, row());
  assertEquals(r.passed, false);
  assertEquals(r.failure_kind, 'type_mismatch');
});

Deno.test('a foreign sender fails rather than silently not matching', () => {
  const r = evaluateRow(SNB, row({ sender: 'CIB' }));
  assertEquals(r.passed, false);
  assertEquals(r.failure_kind, 'sender_scope_mismatch');
});

// ── Applicability: the bank-keyed vacuity problem ──────────────────────────

Deno.test('a same-bank CREDIT row is OUT OF SCOPE, not a false negative', () => {
  // THE FIX for item 4: previously a salary message for this bank made a
  // debit-only rule fail, so the only way to pass was a curated debit-only
  // corpus — the very curation that makes validation vacuous.
  const salary = row({
    id: 'salary', expected_type: 'credit', expected_amount: 9000,
    message_text: 'حوالة راتب\nمبلغ:SAR 9000.00\nمن:EMPLOYER',
  });
  assertEquals(classify(SNB, salary), 'out_of_scope');
  const r = evaluateRow(SNB, salary);
  assertEquals(r.passed, true, 'declining to match another class is correct');
  assertEquals(r.matched, false);
});

Deno.test('but a debit rule that MATCHES a credit row is a false positive', () => {
  // Out-of-scope rows still carry signal: firing on a salary message would
  // write money in the wrong direction.
  const greedy: RuleUnderTest = { ...SNB, message_pattern: '[\\s\\S]*' };
  const salary = row({
    id: 'salary', expected_type: 'credit',
    message_text: 'حوالة راتب\nمبلغ:SAR 9000.00\nمن:EMPLOYER',
  });
  const r = evaluateRow(greedy, salary);
  assertEquals(r.passed, false);
  assertEquals(r.failure_kind, 'out_of_scope_match');
});

Deno.test('a reversal row for the same bank is out of scope too', () => {
  const rev = row({
    id: 'rev', expected_type: 'reversal',
    message_text: 'عكس عملية شراء\nمبلغ:SAR 320.50\nلدى:SHOP',
  });
  assertEquals(classify(SNB, rev), 'out_of_scope');
});

Deno.test('an OTP/promo row must not match', () => {
  const otp = row({ id: 'otp', expected_type: 'ignored', is_otp: true,
    message_text: 'رمز التحقق 123456' });
  assertEquals(classify(SNB, otp), 'negative');
  assertEquals(evaluateRow(SNB, otp).passed, true);
});

// ── Verdict-level: the non-vacuity gate ────────────────────────────────────

Deno.test('a rule with ONLY out-of-scope rows cannot be promoted', () => {
  // Without this gate a debit rule surrounded by credit messages would pass
  // having proved nothing whatsoever.
  const v = validateParser(SNB, [
    row({ id: 'c1', expected_type: 'credit', message_text: 'حوالة راتب\nمبلغ:SAR 9000.00\nمن:EMPLOYER' }),
    row({ id: 'c2', expected_type: 'credit', message_text: 'ايداع\nمبلغ:SAR 500.00\nمن:ACME' }),
  ]);
  assertEquals(v.status, 'failed');
  assertEquals(v.reason?.includes('no applicable positive evidence'), true);
  assertEquals(v.golden_test_count, 0);
});

Deno.test('a rule with only IGNORED rows cannot be promoted', () => {
  const v = validateParser(SNB, [row({ id: 'o', expected_type: 'ignored', is_otp: true })]);
  assertEquals(v.status, 'failed');
});

Deno.test('a positive row that expects NOTHING is not evidence', () => {
  // Missing expected evidence must not silently become PASS.
  const bare = row({
    id: 'bare', expected_amount: null, expected_currency: null, expected_merchant: null,
  });
  const v = validateParser(SNB, [bare]);
  assertEquals(v.status, 'failed', 'a row checking no field proves nothing');
  assertEquals(v.golden_test_count, 0);
});

Deno.test('a mixed same-bank suite passes on real positive evidence', () => {
  // Non-vacuity for every failure assertion above: with one real positive plus
  // out-of-scope and ignored rows, promotion succeeds and the recorded count
  // reflects rows that carried signal.
  const v = validateParser(SNB, [
    row({ id: 'debit-1' }),
    row({ id: 'salary', expected_type: 'credit', message_text: 'حوالة راتب\nمبلغ:SAR 9000.00\nمن:EMPLOYER' }),
    row({ id: 'reversal', expected_type: 'reversal', message_text: 'عكس عملية\nمبلغ:SAR 320.50\nالى:SHOP' }),
    row({ id: 'otp', expected_type: 'ignored', is_otp: true, message_text: 'رمز التحقق 123456' }),
  ]);
  assertEquals(v.status, 'passed');
  assertEquals(v.applicable_positive_count, 1);
  assertEquals(v.out_of_scope_count, 2);
  assertEquals(v.applicable_negative_count, 1);
  assertEquals(v.golden_test_count, 4);
  assertEquals(v.false_positive_count, 0);
});

Deno.test('a row pinned to another parser is not this rule evidence', () => {
  const v = validateParser(SNB, [
    row({ id: 'mine' }),
    row({ id: 'theirs', parser_id: 'rule-other', expected_amount: 999999 }),
  ]);
  assertEquals(v.status, 'passed');
  assertEquals(v.results.length, 1, 'the other rule row is excluded entirely');
});

Deno.test('one failing row fails the whole promotion', () => {
  const v = validateParser(SNB, [row({ id: 'ok' }), row({ id: 'bad', expected_amount: 1 })]);
  assertEquals(v.status, 'failed');
  assertEquals(v.golden_test_count, 0, 'a failed run records no evidence');
});

// ── Reviewer-found gaps (Fable), each reproduced before it was fixed ────────

Deno.test('a currency-only row cannot promote a rule whose AMOUNT is wrong', () => {
  // A1. `"currency": "SAR"` is a LITERAL, so checking it compares a constant to
  // a constant. With expected_amount null this row once counted as verified
  // positive evidence — promoting the exact SNB card-mask defect on one row.
  const v = validateParser(SNB, [
    row({ id: 'currency-only', expected_amount: null, expected_merchant: null }),
  ]);
  assertEquals(v.status, 'failed');
  assertEquals(v.reason?.includes('no applicable positive evidence'), true);
});

Deno.test('a merchant-only row cannot promote an amount-claiming rule either', () => {
  const v = validateParser(SNB, [
    row({ id: 'merchant-only', expected_amount: null, expected_currency: null }),
  ]);
  assertEquals(v.status, 'failed');
});

Deno.test('a rule that claims NO amount may still qualify on other fields', () => {
  // Non-vacuity for the two above: the amount requirement is conditional on the
  // rule actually claiming an amount, not a blanket ban.
  const noAmount: RuleUnderTest = {
    ...SNB,
    extracted_fields: { merchant: 'merchant', type: 'debit' },
  };
  const v = validateParser(noAmount, [
    row({ id: 'm', expected_amount: null, expected_currency: null }),
  ]);
  assertEquals(v.status, 'passed');
});

Deno.test('matching is case-INSENSITIVE, as it is on the device', () => {
  // A2. The device compiles both patterns with caseSensitive: false. A
  // case-sensitive validator records an ignore that will not happen in
  // production, so negative rows were fail-open.
  const promo = row({
    id: 'promo', expected_type: 'ignored', is_promo: true,
    sender: 'snb', // lowercase: the device still matches this
    message_text: 'Special offer: your next PURCHASE over SAR 100 AT NOON',
  });
  const r = evaluateRow(SNB, promo);
  assertEquals(r.matched, true, 'the device would match this promo');
  assertEquals(r.passed, false, 'so the validator must call it a false positive');
  assertEquals(r.failure_kind, 'false_positive');
});

Deno.test('a lowercase sender is accepted, matching the device', () => {
  const r = evaluateRow(SNB, row({ sender: 'snb' }));
  assertEquals(r.passed, true, 'the device matches senders case-insensitively');
});
