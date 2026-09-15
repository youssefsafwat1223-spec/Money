import { assert, assertEquals, assertStringIncludes } from 'jsr:@std/assert@1';
import { IBAN_DETECT_PATTERN, redactPii } from './sms_redaction.ts';

Deno.test('IBANs are redacted — the account rule cannot reach them', () => {
  // The regression: `\b\d{10,20}\b` never matches this, because there is no
  // word boundary between "SA" and the digits. Before the shared floor, this
  // string reached Gemini intact from process-ios-sms and bank-discovery.
  const out = redactPii('حوالة من SA0380000000608010167519 بمبلغ 500 ريال');
  assertStringIncludes(out, '[IBAN]');
  assert(!out.includes('SA0380000000608010167519'));
});

Deno.test('OTP digits are redacted but the cue survives', () => {
  assertEquals(redactPii('Your OTP is 483920'), 'Your OTP is [OTP]');
  assertEquals(redactPii('رمز التحقق: 8391'), 'رمز التحقق: [OTP]');
});

Deno.test('amounts are never redacted by shape', () => {
  // Cue-anchoring exists for exactly this: a bare 4-8 digit run is more often
  // an amount than a passcode, and the proof layer depends on the amount.
  assertEquals(redactPii('شراء بمبلغ 250.75 ريال'), 'شراء بمبلغ 250.75 ريال');
  assertEquals(redactPii('مبلغ 1250 ريال'), 'مبلغ 1250 ريال');
});

Deno.test('card, phone and account rules still apply in the right order', () => {
  assertEquals(redactPii('بطاقة 4539 1488 0343 6467'), 'بطاقة [CARD]');
  assertEquals(redactPii('اتصل 0551234567'), 'اتصل [PHONE]');
  assertEquals(redactPii('اتصل 01012345678'), 'اتصل [PHONE]');
  assertEquals(redactPii('call +966551234567'), 'call [PHONE]');
  assertEquals(redactPii('حساب 1234567890123'), 'حساب [ACCOUNT]');
});

Deno.test('the generic account rule does not eat a card number', () => {
  // A 16-digit run with no separators matches BOTH the card and the account
  // pattern; card must win, which is only true while it runs first.
  assertEquals(redactPii('4539148803436467'), '[CARD]');
});

Deno.test('IBAN_DETECT_PATTERN is not stateful across calls', () => {
  // A /g regex carries lastIndex, so `.test()` on the same input would
  // alternate true/false and a fail-closed gate would pass every other
  // request. This pattern is deliberately non-global.
  const sms = 'SA0380000000608010167519';
  assertEquals(IBAN_DETECT_PATTERN.test(sms), true);
  assertEquals(IBAN_DETECT_PATTERN.test(sms), true);
});
