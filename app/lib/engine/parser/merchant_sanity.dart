/// Merchant-name rules shared by the on-device parser, the AI validator and
/// the backend capture import (mirrors `process-ios-sms/parse.ts`).
///
/// IPN/InstaPay transfers name the payment rail, never the counterparty: the
/// person is not a merchant. And a bare time, date or reference is never a
/// merchant — the backend once read "... on 28/10 at 01:43 AM" as a merchant
/// called "01", so every InstaPay transfer showed its hour as its name.
class MerchantSanity {
  MerchantSanity._();

  static const String instaPay = 'InstaPay';

  static final RegExp _instaPayText = RegExp(
    r'\bipn\b|instapay|إنستا ?باي|انستا ?باي',
    caseSensitive: false,
  );

  static final RegExp _numericOnly = RegExp(
    r'^[\d\s:./\-]+(?:\s*(?:am|pm|ص|م))?$',
    caseSensitive: false,
  );

  static bool isInstaPayText(String text) => _instaPayText.hasMatch(text);

  static bool isNumericOnly(String merchant) =>
      _numericOnly.hasMatch(merchant.trim());

  /// The merchant to store for [message]: "InstaPay" for an IPN/InstaPay
  /// transfer, null for a time/date/reference, otherwise [merchant].
  static String? forMessage(String? merchant, String message) {
    if (isInstaPayText(message)) return instaPay;
    if (merchant == null || isNumericOnly(merchant)) return null;
    return merchant;
  }
}
