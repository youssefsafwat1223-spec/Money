class ManualPasteSplitter {
  const ManualPasteSplitter._();

  static List<String> split(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return const [];

    final blankSeparated = text
        .split(RegExp(r'\n\s*\n+'))
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList(growable: false);
    if (blankSeparated.length > 1 &&
        blankSeparated.every(_looksLikeTransactionMessage)) {
      return blankSeparated;
    }

    final lines = text
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    if (lines.length > 1 && lines.every(_looksLikeSingleLineTransaction)) {
      return lines;
    }

    final markerSplit = _splitByStartMarkers(text);
    if (markerSplit.length > 1 &&
        markerSplit.every(_looksLikeTransactionMessage)) {
      return markerSplit;
    }

    return [text];
  }

  static List<String> _splitByStartMarkers(String text) {
    final starts = RegExp(
      r'(?=(?:IPN transfer|Your Debit Card|Your account was|تم\s|عملية\s|مشترياتك|حوالة\s|تحويل\s))',
      caseSensitive: false,
    ).allMatches(text).map((match) => match.start).toList(growable: false);
    if (starts.length <= 1 || starts.first != 0) return [text.trim()];

    final parts = <String>[];
    for (var i = 0; i < starts.length; i++) {
      final start = starts[i];
      final end = i == starts.length - 1 ? text.length : starts[i + 1];
      final part = text.substring(start, end).trim();
      if (part.isNotEmpty) parts.add(part);
    }
    return parts;
  }

  static bool _looksLikeSingleLineTransaction(String text) {
    if (text.length < 18) return false;
    return _looksLikeTransactionMessage(text);
  }

  static bool _looksLikeTransactionMessage(String text) {
    final lower = text.toLowerCase();
    final hasAmount = RegExp(
      r'(\b(?:egp|sar|usd|aed|eur|gbp)\b|ج\.?م|جم|ريال|ر\.س|درهم|دولار)\s*[\d,]+(?:\.\d+)?|[\d,]+(?:\.\d+)?\s*(?:\b(?:egp|sar|usd|aed|eur|gbp)\b|ج\.?م|جم|ريال|ر\.س|درهم|دولار)',
      caseSensitive: false,
    ).hasMatch(text);
    if (!hasAmount) return false;

    final hasTransactionWord = [
      'transfer',
      'transaction',
      'credited',
      'debit',
      'purchase',
      'withdrawal',
      'ipn',
      'تحويل',
      'حوالة',
      'شراء',
      'مشتريات',
      'خصم',
      'إيداع',
      'ايداع',
      'تم',
    ].any(lower.contains);
    if (!hasTransactionWord) return false;

    final hasAnchor = RegExp(
      r'\b(ref#?|on|at|from|to)\b|مرجع|بطاقة|حساب|رقم|يوم|الساعة|\d{1,2}[:/.-]\d{1,2}',
      caseSensitive: false,
    ).hasMatch(text);
    return hasAnchor;
  }
}
