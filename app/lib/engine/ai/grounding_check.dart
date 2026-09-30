class GroundingCheck {
  static bool verify({required double amount, required String sanitizedText}) {
    if (amount <= 0) return false;
    final candidates = _buildCandidates(amount);
    return candidates.any((c) => sanitizedText.contains(c));
  }

  static List<String> _buildCandidates(double amount) {
    final western = [
      amount.toStringAsFixed(2),
      amount.toStringAsFixed(3),
      amount.toStringAsFixed(1),
      amount.toStringAsFixed(0),
    ];
    final all = <String>{...western};
    all.addAll(western.map(_toArabicIndic));
    // Thousands-separated forms (1,250.00 / ١٬٢٥٠٫٠٠). Additive only.
    for (final plain in western) {
      final grouped = _group(plain);
      if (grouped == plain) continue;
      all.add(grouped);
      final arabic = _toArabicIndic(grouped);
      all.add(arabic);
      all.add(arabic.replaceAll(',', '٬'));
      all.add(arabic.replaceAll(',', '٬').replaceAll('.', '٫'));
    }
    return all.toList();
  }

  /// Inserts a comma every three integer digits: `1250.00` -> `1,250.00`.
  static String _group(String plain) {
    final dot = plain.indexOf('.');
    final integer = dot < 0 ? plain : plain.substring(0, dot);
    final fraction = dot < 0 ? '' : plain.substring(dot);
    if (integer.length <= 3) return plain;
    final buffer = StringBuffer();
    for (var i = 0; i < integer.length; i++) {
      if (i > 0 && (integer.length - i) % 3 == 0) buffer.write(',');
      buffer.write(integer[i]);
    }
    return '$buffer$fraction';
  }

  static const _westernDigits = [
    '0',
    '1',
    '2',
    '3',
    '4',
    '5',
    '6',
    '7',
    '8',
    '9'
  ];
  static const _arabicDigits = [
    '٠',
    '١',
    '٢',
    '٣',
    '٤',
    '٥',
    '٦',
    '٧',
    '٨',
    '٩'
  ];

  static String _toArabicIndic(String s) {
    var r = s;
    for (var i = 0; i < 10; i++) {
      r = r.replaceAll(_westernDigits[i], _arabicDigits[i]);
    }
    return r;
  }
}
