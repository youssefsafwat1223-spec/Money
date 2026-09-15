/// The PII floor every path that sends SMS text off-device must apply.
///
/// This exists because three server functions each carried their own copy of
/// `reSanitize`, and two of them — `process-ios-sms` and `bank-discovery`,
/// both of which forward the text to Gemini — were missing the IBAN and OTP
/// rules that `parse-sms` and the Dart client sanitizer have. A full Saudi
/// IBAN therefore reached the model untouched: the digits-only account rule
/// cannot match it, because there is no word boundary between `SA` and the
/// digits that follow.
///
/// Callers may add rules on top (beneficiary stripping, bank-specific account
/// cues); they may not subtract. Keep in lockstep with
/// `app/lib/engine/privacy/sms_sanitizer.dart` and
/// `app/ios/BankMessageShortcuts/BankMessageShortcuts.swift`.

/// Every digit shape this market actually sends: Latin, Arabic-Indic
/// (U+0660-0669) and extended Arabic-Indic (U+06F0-06F9).
///
/// The patterns below used ASCII `\d`, so a card, IBAN or account number
/// written in Arabic-Indic digits was forwarded to the model untouched. The
/// digits are matched in place rather than normalised away: the proof layer
/// compares model output against spans of the very string that was sent.
const D = '[0-9\u0660-\u0669\u06F0-\u06F9]';

/// `\b` is defined over [A-Za-z0-9_] alone and does not treat U+0660 as a word
/// character, so against an Arabic-Indic run it puts a "boundary" mid-digits
/// and matches a fragment. These are that assertion widened; on ASCII input
/// they are exactly equivalent to `\b`.
const NB = '(?<![0-9\u0660-\u0669\u06F0-\u06F9A-Za-z_])';
const NB_END = '(?![0-9\u0660-\u0669\u06F0-\u06F9A-Za-z_])';

/// ISO 13616. Alphanumeric, so the digits-only account rule can never catch
/// it. The country code is matched case-insensitively, because
/// `sa0380000000608010167519` is the same identifier as the upper-case form
/// and used to pass straight through.
///
/// Deliberately NOT global: this one is for `.test()` in fail-closed checks,
/// and a /g regex carries `lastIndex` between calls, so it would alternate
/// true/false on the same input.
export const IBAN_DETECT_PATTERN = new RegExp(
  `${NB}[A-Za-z]{2}${D}{2}[A-Za-z0-9\u0660-\u0669\u06F0-\u06F9]{11,30}${NB_END}`,
);

/// CUE-ANCHORED on purpose. A bare 4-8 digit run is far more often an amount
/// than a passcode, so redacting by shape alone would destroy the value the
/// proof layer exists to establish. The cue is kept so the message stays
/// classifiable as an OTP.
// Not exported: /g carries `lastIndex`, so it is safe with `.replace()` here
// and unsafe with `.test()` anywhere else.
const OTP_PATTERN = new RegExp(
  `((?:otp|one[- ]?time(?:\\s+password)?|verification\\s+code|رمز\\s+التحقق|كود\\s+التحقق|رمز\\s+الدخول)(?:\\s+(?:is|هو))?\\s*:?\\s*)${D}{4,8}`,
  'gi',
);

const CARD_PATTERN = new RegExp(
  `${NB}${D}{4}[\\s-]?${D}{4}[\\s-]?${D}{4}[\\s-]?${D}{4}${NB_END}`,
  'g',
);
// The leading 0 and 5 may themselves be Arabic-Indic, so they are classes.
const SAUDI_PHONE_PATTERN = new RegExp(
  `${NB}[0\u0660\u06F0][5\u0665\u06F5]${D}{8}${NB_END}`,
  'g',
);
const EGYPT_PHONE_PATTERN = new RegExp(
  `${NB}[0\u0660\u06F0][1\u0661\u06F1][0125\u0660\u0661\u0662\u0665\u06F0\u06F1\u06F2\u06F5]${D}{8}${NB_END}`,
  'g',
);
const INTL_PHONE_PATTERN = new RegExp(`\\+${D}{7,15}${NB_END}`, 'g');
const IBAN_PATTERN = new RegExp(IBAN_DETECT_PATTERN.source, 'g');
const ACCOUNT_PATTERN = new RegExp(`${NB}${D}{10,20}${NB_END}`, 'g');

/// Redacts card numbers, phone numbers, IBANs, OTPs and account numbers.
///
/// ORDER MATTERS: the specific patterns run first, and the generic account
/// rule runs last, because it would otherwise eat the digit run inside a more
/// specific match.
export function redactPii(text: string): string {
  return text
    .replace(CARD_PATTERN, '[CARD]')
    .replace(SAUDI_PHONE_PATTERN, '[PHONE]')
    .replace(EGYPT_PHONE_PATTERN, '[PHONE]')
    .replace(INTL_PHONE_PATTERN, '[PHONE]')
    .replace(IBAN_PATTERN, '[IBAN]')
    .replace(OTP_PATTERN, '$1[OTP]')
    .replace(ACCOUNT_PATTERN, '[ACCOUNT]');
}
