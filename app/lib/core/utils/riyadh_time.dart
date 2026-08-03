class RiyadhTime {
  RiyadhTime._();

  /// Legacy constant kept for source compatibility only. Calendar boundaries
  /// now follow the device-local timezone instead of a fixed Riyadh offset.
  static const Duration offset = Duration(hours: 3);

  static DateTime toRiyadh(DateTime dateTime) {
    return dateTime.toLocal();
  }

  static DateTime fromRiyadh(DateTime dateTime) {
    return DateTime(
      dateTime.year,
      dateTime.month,
      dateTime.day,
      dateTime.hour,
      dateTime.minute,
      dateTime.second,
      dateTime.millisecond,
      dateTime.microsecond,
    );
  }

  static DateTime startOfDay(DateTime dateTime) {
    final local = dateTime.toLocal();
    return DateTime(local.year, local.month, local.day);
  }

  static DateTime endOfDay(DateTime dateTime) {
    return startOfDay(dateTime).add(const Duration(days: 1));
  }

  /// MALI-062n — the canonical week starts on **Saturday** (the Gulf/Arabic
  /// convention this app targets; the previous `weekday % 7` was a misnamed
  /// Sunday-start that mislabelled every weekly total). Dart weekday: Mon=1…Sun=7;
  /// `(weekday + 1) % 7` maps Sat→0, Sun→1, …, Fri→6 = days since the week start.
  static DateTime startOfWeek(DateTime dateTime) {
    final local = dateTime.toLocal();
    final daysSinceSaturday = (local.weekday + 1) % 7;
    return DateTime(local.year, local.month, local.day)
        .subtract(Duration(days: daysSinceSaturday));
  }

  static DateTime endOfWeek(DateTime dateTime) {
    return startOfWeek(dateTime).add(const Duration(days: 7));
  }

  static DateTime startOfMonth(DateTime dateTime) {
    final local = dateTime.toLocal();
    return DateTime(local.year, local.month);
  }

  static DateTime endOfMonth(DateTime dateTime) {
    final local = dateTime.toLocal();
    return DateTime(local.year, local.month + 1);
  }

  static DateTime activityDate(DateTime dateTime) {
    final local = dateTime.toLocal();
    return DateTime(local.year, local.month, local.day);
  }

  static int dayGap(DateTime from, DateTime to) {
    final fromDay = activityDate(from);
    final toDay = activityDate(to);
    return toDay.difference(fromDay).inDays;
  }

  static bool isSameWeek(DateTime a, DateTime b) {
    return startOfWeek(a) == startOfWeek(b);
  }
}
