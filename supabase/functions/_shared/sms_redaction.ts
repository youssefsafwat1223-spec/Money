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

/// ISO 13616. Alphanumeric, so the digits-only account rule can never catch
/// it. Deliberately NOT global: this one is for `.test()` in fail-closed
/// checks, and a /g regex carries `lastIndex` between calls, so it would
/// alternate true/false on the same input.
export const IBAN_DETECT_PATTERN = /\b[A-Z]{2}\d{2}[A-Z0-9]{11,30}\b/;

/// CUE-ANCHORED on purpose. A bare 4-8 digit run is far more often an amount
/// than a passcode, so redacting by shape alone would destroy the value the
/// proof layer exists to establish. The cue is kept so the message stays
/// classifiable as an OTP.
// Not exported: /g carries `lastIndex`, so it is safe with `.replace()` here
// and unsafe with `.test()` anywhere else.
const OTP_PATTERN =
  /((?:otp|one[- ]?time(?:\s+password)?|verification\s+code|رمز\s+التحقق|كود\s+التحقق|رمز\s+الدخول)(?:\s+(?:is|هو))?\s*:?\s*)\d{4,8}/gi;

/// Redacts card numbers, phone numbers, IBANs, OTPs and account numbers.
///
/// ORDER MATTERS: the specific patterns run first, and the generic account
/// rule runs last, because it would otherwise eat the digit run inside a more
/// specific match.
export function redactPii(text: string): string {
  return text
    .replace(/\b\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4}\b/g, '[CARD]')
    .replace(/\b05\d{8}\b/g, '[PHONE]')
    .replace(/\b01[0125]\d{8}\b/g, '[PHONE]')
    .replace(/\+\d{7,15}\b/g, '[PHONE]')
    .replace(/\b[A-Z]{2}\d{2}[A-Z0-9]{11,30}\b/g, '[IBAN]')
    .replace(OTP_PATTERN, '$1[OTP]')
    .replace(/\b\d{10,20}\b/g, '[ACCOUNT]');
}
