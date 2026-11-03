import 'normalizer.dart';

class TransactionTimestampExtractor {
  TransactionTimestampExtractor._();

  /// Optional meridiem after a clock time (group 1 of this fragment): AM/PM in
  /// any dots/case, or Arabic ص/م/صباحا/مساء. It carries its own boundary, so
  /// "13:29 من" or "10:00 amount" is not read as a meridiem.
  static const String meridiem =
      r'(?:\s*(a\.?\s?m\.?|p\.?\s?m\.?|صباحا|مساء|ص|م)(?![a-z\u0621-\u064A]))?';

  static final RegExp _isoDateTime = RegExp(
    r'\b([0-9]{4})-([0-9]{1,2})-([0-9]{1,2})'
    r'(?:\s*(?:T|at|الساعة|الساعه)?\s*([0-9]{1,2}):([0-9]{2})'
    '$meridiem'
    r')?(?![0-9a-z_])',
    caseSensitive: false,
  );
  static final RegExp _dmyDateTime = RegExp(
    r'\b([0-9]{1,2})[/-]([0-9]{1,2})[/-]([0-9]{2,4})'
    r'(?:\s*(?:at|الساعة|الساعه)?\s*([0-9]{1,2}):([0-9]{2})'
    '$meridiem'
    r')?(?![0-9a-z_])',
    caseSensitive: false,
  );
  static final RegExp _shortYmdDateTime = RegExp(
    r'\b([0-9]{2})-([0-9]{1,2})-([0-9]{1,2})'
    r'(?:\s*(?:at|الساعة|الساعه)?\s*([0-9]{1,2}):([0-9]{2})'
    '$meridiem'
    r')?(?![0-9a-z_])',
    caseSensitive: false,
  );
  static final RegExp _dashDmyDate = RegExp(
    r'\b([0-9]{1,2})-([0-9]{1,2})-([0-9]{4})\b',
    caseSensitive: false,
  );

  static DateTime? extract(String rawText) {
    final text = Normalizer.normalize(rawText);

    final iso = _isoDateTime.firstMatch(text);
    if (iso != null) {
      return _safeDate(
        int.parse(iso.group(1)!),
        int.parse(iso.group(2)!),
        int.parse(iso.group(3)!),
        _hourWithMeridiem(
          iso.group(4) == null ? 0 : int.parse(iso.group(4)!),
          iso.group(6),
        ),
        iso.group(5) == null ? 0 : int.parse(iso.group(5)!),
      );
    }

    final shortYmd = _shortYmdDateTime.firstMatch(text);
    if (shortYmd != null) {
      final year = int.parse(shortYmd.group(1)!);
      final month = int.parse(shortYmd.group(2)!);
      final day = int.parse(shortYmd.group(3)!);
      if (year <= 50 && month <= 12 && day <= 31) {
        return _safeDate(
          2000 + year,
          month,
          day,
          _hourWithMeridiem(
            shortYmd.group(4) == null ? 0 : int.parse(shortYmd.group(4)!),
            shortYmd.group(6),
          ),
          shortYmd.group(5) == null ? 0 : int.parse(shortYmd.group(5)!),
        );
      }
    }

    final dmy = _dmyDateTime.firstMatch(text);
    if (dmy != null) {
      return _safeDate(
        _normalizeYear(int.parse(dmy.group(3)!)),
        int.parse(dmy.group(2)!),
        int.parse(dmy.group(1)!),
        _hourWithMeridiem(
          dmy.group(4) == null ? 0 : int.parse(dmy.group(4)!),
          dmy.group(6),
        ),
        dmy.group(5) == null ? 0 : int.parse(dmy.group(5)!),
      );
    }

    final dashDmy = _dashDmyDate.firstMatch(text);
    if (dashDmy == null) return null;
    return _safeDate(
      int.parse(dashDmy.group(3)!),
      int.parse(dashDmy.group(2)!),
      int.parse(dashDmy.group(1)!),
      0,
      0,
    );
  }

  static int _normalizeYear(int year) => year < 100 ? 2000 + year : year;

  static int _hourWithMeridiem(int hour, String? marker) =>
      hourWithMeridiem(hour, marker);

  /// 12 AM = 00, 12 PM = 12, 1-11 PM = +12. No marker = 24-hour clock.
  static int hourWithMeridiem(int hour, String? marker) {
    if (marker == null || hour < 1 || hour > 12) return hour;
    final m = marker.toLowerCase().replaceAll(RegExp(r'[.\s]'), '');
    final pm = m == 'pm' || m == 'م' || m.startsWith('مساء');
    if (pm) return hour == 12 ? 12 : hour + 12;
    return hour == 12 ? 0 : hour;
  }

  static DateTime? _safeDate(
    int year,
    int month,
    int day,
    int hour,
    int minute,
  ) {
    try {
      final date = DateTime(year, month, day, hour, minute);
      if (date.year != year || date.month != month || date.day != day) {
        return null;
      }
      return date;
    } catch (_) {
      return null;
    }
  }
}
