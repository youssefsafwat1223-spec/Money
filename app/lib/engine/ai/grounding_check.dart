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
    return all.toList();
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
