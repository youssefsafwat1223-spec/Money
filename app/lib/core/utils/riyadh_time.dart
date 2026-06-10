class RiyadhTime {
  RiyadhTime._();

  static const Duration offset = Duration(hours: 3);

  static DateTime toRiyadh(DateTime dateTime) {
    final utc = dateTime.isUtc ? dateTime : dateTime.toUtc();
    return utc.add(offset);
  }

  static DateTime fromRiyadh(DateTime dateTime) {
    final normalized = DateTime.utc(
      dateTime.year,
      dateTime.month,
      dateTime.day,
      dateTime.hour,
      dateTime.minute,
      dateTime.second,
      dateTime.millisecond,
      dateTime.microsecond,
    );
    return normalized.subtract(offset);
  }

  static DateTime startOfDay(DateTime dateTime) {
    final riyadh = toRiyadh(dateTime);
    return DateTime.utc(riyadh.year, riyadh.month, riyadh.day)
        .subtract(offset);
  }

  static DateTime endOfDay(DateTime dateTime) {
    return startOfDay(dateTime).add(const Duration(days: 1));
  }

  static DateTime startOfWeek(DateTime dateTime) {
    final riyadh = toRiyadh(dateTime);
    final daysSinceSaturday = riyadh.weekday % 7;
    return DateTime.utc(riyadh.year, riyadh.month, riyadh.day)
        .subtract(Duration(days: daysSinceSaturday))
        .subtract(offset);
  }

  static DateTime endOfWeek(DateTime dateTime) {
    return startOfWeek(dateTime).add(const Duration(days: 7));
  }

  static DateTime startOfMonth(DateTime dateTime) {
    final riyadh = toRiyadh(dateTime);
    return DateTime.utc(riyadh.year, riyadh.month).subtract(offset);
  }

  static DateTime endOfMonth(DateTime dateTime) {
    final riyadh = toRiyadh(dateTime);
    return DateTime.utc(riyadh.year, riyadh.month + 1).subtract(offset);
  }

  static DateTime activityDate(DateTime dateTime) {
    final riyadh = toRiyadh(dateTime);
    return DateTime.utc(riyadh.year, riyadh.month, riyadh.day);
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
