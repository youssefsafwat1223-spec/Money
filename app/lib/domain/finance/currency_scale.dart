/// MALI-026 (Phase-8 B8-0) — the explicit, tested currency-scale registry.
///
/// Decision 2: a KNOWN supported currency maps to an explicit ISO-4217 minor-unit
/// scale; an UNKNOWN code is an explicit UNSUPPORTED state. There is NO silent
/// "assume 2 decimals" for PERSISTED Money (migration / backup restore / sync /
/// machine import / Money construction). A separate display-only fallback lives
/// in `money_format.dart` (`currencyDecimalDigits`, default 2) for non-financial
/// presentation surfaces — it must never mint canonical persisted minor units.
library;

/// Thrown when persisted-Money code encounters a currency with no registered
/// scale. Callers (migration preflight, sync, import) must handle it explicitly
/// — never guess a scale.
class UnsupportedCurrencyException implements Exception {
  const UnsupportedCurrencyException(this.currencyCode);
  final String currencyCode;
  @override
  String toString() =>
      'UnsupportedCurrencyException: no registered minor-unit scale for '
      '"$currencyCode"';
}

/// ISO-4217 minor-unit scale per currency the app supports (the set mirrors
/// `Currency.arabicLabel`). Everything NOT listed is unsupported for persisted
/// Money. Grouped by scale for auditability.
const Map<String, int> kCurrencyScale = {
  // ── 3 minor digits ──────────────────────────────────────────────────────
  'KWD': 3, 'BHD': 3, 'OMR': 3, 'JOD': 3, 'TND': 3, 'LYD': 3, 'IQD': 3,
  // ── 0 minor digits ──────────────────────────────────────────────────────
  'JPY': 0, 'KRW': 0, 'ISK': 0, 'CLP': 0, 'VND': 0, 'XAF': 0, 'XOF': 0,
  'UGX': 0, 'RWF': 0, 'DJF': 0, 'GNF': 0, 'PYG': 0, 'KMF': 0,
  // ── 2 minor digits (all remaining supported codes) ──────────────────────
  'SAR': 2, 'AED': 2, 'EGP': 2, 'QAR': 2, 'ILS': 2, 'LBP': 2, 'SYP': 2,
  'MAD': 2, 'MRU': 2, 'DZD': 2, 'SDG': 2, 'YER': 2, 'SOS': 2, 'TRY': 2,
  'USD': 2, 'EUR': 2, 'GBP': 2, 'INR': 2, 'PKR': 2, 'BDT': 2, 'PHP': 2,
  'IDR': 2, 'MYR': 2, 'SGD': 2, 'NGN': 2, 'KES': 2, 'ZAR': 2, 'ETB': 2,
  'GHS': 2, 'TZS': 2,
};

String _normalize(String code) => code.trim().toUpperCase();

/// Whether [currencyCode] has a registered scale (is supported for persisted
/// Money).
bool isSupportedCurrency(String currencyCode) =>
    kCurrencyScale.containsKey(_normalize(currencyCode));

/// The minor-unit scale for a SUPPORTED currency. Throws
/// [UnsupportedCurrencyException] for an unknown code — persisted Money never
/// guesses a scale.
int currencyScale(String currencyCode) {
  final code = _normalize(currencyCode);
  final scale = kCurrencyScale[code];
  if (scale == null) throw UnsupportedCurrencyException(code);
  return scale;
}
