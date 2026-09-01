import '../models/transaction_type.dart';

/// Sanitizes a raw bank SMS before sending to any off-device AI service.
///
/// The sanitized string is for AI consumption ONLY. The raw SMS is always
/// stored locally and fed to the rule-based parser unchanged.
///
/// Strip order matters — phone patterns must run before the broad
/// account-number pattern so phone digits are not double-redacted.
///
/// Transfer vs purchase distinction (owner decision 2026-06-16):
/// - [TransactionType.payment] / POS: merchant name is kept. AI needs it to
///   categorize the transaction (merchant = business entity, not PII).
/// - [TransactionType.transfer] / unknown: beneficiary content after إلى: / To:
///   is STRIPPED. The beneficiary is a real person's name — third-party PII
///   that must never leave the device.
class SmsSanitizer {
  SmsSanitizer._();

  // ── Card numbers ─────────────────────────────────────────────────────────
  // Full 16-digit cards with optional separators. Does NOT match *1234 masked
  // forms (starts with *) — those are intentionally kept (not PII).
  static final _cardNumber = RegExp(
    r'\b\d{4}[\s\-]?\d{4}[\s\-]?\d{4}[\s\-]?\d{4}\b',
  );

  // ── Phone numbers ─────────────────────────────────────────────────────────
  // Saudi mobile: 05XXXXXXXX (10 digits starting with 05)
  static final _saudiPhone = RegExp(r'\b05\d{8}\b');
  // Egyptian mobile: 01[0125]XXXXXXXX
  static final _egyptPhone = RegExp(r'\b01[0125]\d{8}\b');
  // International: +CC followed by 7–14 digits
  static final _intlPhone = RegExp(r'\+\d{7,15}\b');

  // ── IBAN ─────────────────────────────────────────────────────────────────
  // ISO 13616: two country letters, two check digits, then up to 30
  // alphanumerics. The account pattern below is digits-only and therefore
  // CANNOT match an IBAN — `SA0380000000608010167519` passed through
  // untouched before this existed, which is a full account identifier sent to
  // a third party. Runs BEFORE the digit rule so the more specific form wins.
  static final _iban = RegExp(
    r'\b[A-Z]{2}\d{2}[A-Z0-9]{11,30}\b',
  );

  // ── One-time passcodes ───────────────────────────────────────────────────
  // CUE-ANCHORED on purpose. A bare 4-6 digit run is far more often an amount
  // or a card suffix than a passcode, so redacting by shape alone would
  // destroy the very value the proof layer exists to establish. Only digits
  // that FOLLOW an explicit OTP cue are removed, and the cue itself is kept so
  // the message stays classifiable as an OTP.
  static final _otp = RegExp(
    r'((?:otp|one[- ]?time(?:\s+password)?|verification\s+code|'
    r'رمز\s+التحقق|كود\s+التحقق|رمز\s+الدخول)'
    r'(?:\s+(?:is|هو))?\s*:?\s*)\d{4,8}',
    caseSensitive: false,
  );

  // ── Account numbers ───────────────────────────────────────────────────────
  // Any 10–20 consecutive digits that were NOT already replaced by the phone
  // or card patterns above. Amounts are ≤ 9 digits without a currency context;
  // real account numbers are 10+.
  static final _accountNumber = RegExp(r'\b\d{10,20}\b');

  // ── Beneficiary / transfer recipient ─────────────────────────────────────
  // Captures everything after إلى: / الى: / To: to end of line.
  // Applied only when stripping is required (see [sanitize]).
  static final _beneficiaryAr = RegExp(
    r'(إلى|الى)\s*:?\s*.+',
    caseSensitive: false,
  );
  static final _beneficiaryEn = RegExp(
    r'\bTo\s*:\s*.+',
    caseSensitive: false,
  );

  // ── Arabic greetings with personal names ─────────────────────────────────
  // "عزيزي أحمد" / "عزيزتي سارة" — name follows the greeting word.
  // Does NOT match "عميلنا العزيز" (no personal name after it).
  static final _greeting = RegExp(
    r'(عزيزي|عزيزتي)\s+\S+',
    caseSensitive: false,
  );

  // ── Read-only pattern accessors ──────────────────────────────────────────
  // Exposed so `sanitization_edit_map.dart` can run the SAME passes in the
  // SAME order and record where every character went. Sharing the patterns is
  // what makes the edit map's output byte-identical to [sanitize] by
  // construction rather than by a second implementation that could drift.
  static RegExp get cardNumberPattern => _cardNumber;
  static RegExp get saudiPhonePattern => _saudiPhone;
  static RegExp get egyptPhonePattern => _egyptPhone;
  static RegExp get intlPhonePattern => _intlPhone;
  static RegExp get ibanPattern => _iban;
  static RegExp get otpPattern => _otp;
  static RegExp get accountNumberPattern => _accountNumber;
  static RegExp get beneficiaryArPattern => _beneficiaryAr;
  static RegExp get beneficiaryEnPattern => _beneficiaryEn;
  static RegExp get greetingPattern => _greeting;

  /// Returns a sanitized copy of [rawSms] safe for sending to an AI service.
  ///
  /// [detectedType] is the type detected by the rule-based parser before
  /// falling through to AI, or null if the parser produced no result:
  ///
  /// - `payment` → keep `إلى:` / `To:` content (it is a business merchant name,
  ///   not a person; AI needs it for categorization).
  /// - `transfer`, `income`, or `null` (unknown) → strip beneficiary / sender
  ///   names entirely. Better to over-redact an unknown message than leak a
  ///   third party's identity.
  /// - `withdrawal` → nothing extra to strip (ATM, no counterparty name).
  static String sanitize(String rawSms, {TransactionType? detectedType}) {
    var text = rawSms;

    // 1. Full card numbers (before broad account pattern to avoid overlap)
    text = text.replaceAll(_cardNumber, '[CARD]');

    // 2. Phone numbers (before broad account pattern to avoid overlap)
    text = text.replaceAll(_saudiPhone, '[PHONE]');
    text = text.replaceAll(_egyptPhone, '[PHONE]');
    text = text.replaceAll(_intlPhone, '[PHONE]');

    // 3. IBANs (alphanumeric, so the digit rule below cannot catch them)
    text = text.replaceAll(_iban, '[IBAN]');

    // 4. One-time passcodes, cue-anchored so amounts are never destroyed
    text = text.replaceAllMapped(_otp, (m) => '${m.group(1)!}[OTP]');

    // 5. Long digit sequences not already replaced (account substrings)
    text = text.replaceAll(_accountNumber, '[ACCOUNT]');

    // 6. Beneficiary / recipient names for non-purchase types
    final stripBeneficiary = detectedType == null ||
        detectedType == TransactionType.transfer ||
        detectedType == TransactionType.income;

    if (stripBeneficiary) {
      text = text.replaceAllMapped(
          _beneficiaryAr, (m) => '${m.group(1)!}: [REDACTED]');
      text = text.replaceAll(_beneficiaryEn, 'To: [REDACTED]');
    }

    // 7. Arabic greetings that include a personal name
    text = text.replaceAll(_greeting, '[REDACTED]');

    return text.trim();
  }
}
