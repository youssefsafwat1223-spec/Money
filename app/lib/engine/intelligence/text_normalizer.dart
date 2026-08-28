/// Arabic + Latin text normalisation for merchant matching.
///
/// Bank messages spell the same merchant many ways. «كارفور» arrives with and
/// without diacritics, with أ/إ/آ where the catalog has ا, with ة where the
/// catalog has ه, with Arabic-Indic digits, wrapped in acquirer boilerplate
/// («شراء من», "POS PURCHASE"), and often transliterated into Latin. Exact
/// substring matching — which is what the categorizer does today — sees all of
/// those as different merchants.
///
/// This is deliberately NOT a general Arabic NLP normaliser. It does the small
/// set of transformations that are safe for merchant identity and nothing else:
/// every rule here either removes noise the bank added, or collapses an
/// orthographic variant that no two distinct merchants rely on to tell
/// themselves apart.
library;

/// Arabic diacritics (tashkeel) and the tatweel elongation mark. Decorative for
/// merchant identity — «كَارْفُور» and «كارفور» are the same shop.
final RegExp _diacritics = RegExp(r'[ؐ-ًؚ-ٰٟـ]');

/// Boilerplate the acquirer/bank wraps around the real merchant name. Anchored
/// so a merchant that merely CONTAINS one of these words is untouched.
final RegExp _leadingBoilerplate = RegExp(
  r'^(?:'
  r'شراء\s+من|شراء|مشتريات\s+من|مشتريات|عملية\s+شراء|دفع\s+الى|دفع|'
  r'pos\s+purchase|pos|purchase\s+at|purchase|payment\s+to|payment|'
  r'card\s+purchase|point\s+of\s+sale'
  r')\s+',
  caseSensitive: false,
);

/// Trailing terminal/reference noise: «- فرع ١٢٣», "TERM 4471", "REF:99".
final RegExp _trailingNoise = RegExp(
  r'[\s\-–—]*(?:'
  r'فرع|ترمينال|مرجع|term(?:inal)?|ref(?:erence)?|txn|trace|auth'
  r')[\s:#]*[0-9]*$',
  caseSensitive: false,
);

/// Collapsed whitespace, including the Arabic comma and assorted separators.
final RegExp _separators = RegExp(r'[\s،,;|/\\]+');

const _alefForms = {'أ': 'ا', 'إ': 'ا', 'آ': 'ا', 'ٱ': 'ا'};
const _otherFolds = {
  'ة': 'ه', // teh marbuta → heh
  'ى': 'ي', // alef maksura → yeh
  'ؤ': 'و',
  'ئ': 'ي',
  'ک': 'ك', // Persian kaf → Arabic kaf
  'گ': 'ك',
  'ی': 'ي', // Persian yeh
};

/// Arabic-Indic (٠-٩) and Eastern Arabic-Indic (۰-۹) digits → ASCII.
String _foldDigits(String s) {
  final b = StringBuffer();
  for (final rune in s.runes) {
    if (rune >= 0x0660 && rune <= 0x0669) {
      b.writeCharCode(rune - 0x0660 + 0x30);
    } else if (rune >= 0x06F0 && rune <= 0x06F9) {
      b.writeCharCode(rune - 0x06F0 + 0x30);
    } else {
      b.writeCharCode(rune);
    }
  }
  return b.toString();
}

/// Normalises a merchant string for matching.
///
/// The result is a MATCHING KEY, not a display name. It is intentionally lossy
/// and must never be shown to the user or used as a persisted identity — see
/// the write-fence in `merchant_classifier.dart`.
String normalizeMerchant(String raw) {
  var s = raw.trim().toLowerCase();
  s = _foldDigits(s);
  s = s.replaceAll(_diacritics, '');

  final b = StringBuffer();
  for (final ch in s.split('')) {
    b.write(_alefForms[ch] ?? _otherFolds[ch] ?? ch);
  }
  s = b.toString();

  // Boilerplate strip runs AFTER folding so «شراء من» matches regardless of
  // how the bank spelled it. Repeat once: some banks stack two prefixes.
  for (var i = 0; i < 2; i++) {
    final stripped = s.replaceFirst(_leadingBoilerplate, '');
    if (stripped == s) break;
    s = stripped;
  }
  s = s.replaceFirst(_trailingNoise, '');
  s = s.replaceAll(_separators, ' ').trim();
  return s;
}
