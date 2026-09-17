import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:money_companion/l10n/app_localizations.dart';

/// تنسيق المبالغ والتواريخ — أرقام غربية (tabular)، نبرة عربية.
class Formatters {
  Formatters._();

  static final NumberFormat _money = NumberFormat('#,##0.00', 'en_US');
  static final NumberFormat _int = NumberFormat('#,##0', 'en_US');

  static const List<String> _arMonths = [
    'يناير',
    'فبراير',
    'مارس',
    'أبريل',
    'مايو',
    'يونيو',
    'يوليو',
    'أغسطس',
    'سبتمبر',
    'أكتوبر',
    'نوفمبر',
    'ديسمبر',
  ];

  static const List<String> _enMonths = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  /// "45.00"
  static String amount(double value) => _money.format(value);

  /// "1,240"
  static String integer(num value) => _int.format(value);

  /// مبلغ بإشارة: مصروف بالسالب، دخل/استرداد بالموجب.
  static String signed(double value, {required bool isExpense}) {
    final formatted = _money.format(value.abs());
    return isExpense ? '−$formatted' : '+$formatted';
  }

  static const List<String> _arWeekdays = [
    'الإثنين',
    'الثلاثاء',
    'الأربعاء',
    'الخميس',
    'الجمعة',
    'السبت',
    'الأحد',
  ];

  static const List<String> _enWeekdays = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];

  /// Short weekday for axis labels. English is abbreviated because a chart
  /// tick has room for "Wed", not "Wednesday"; the Arabic forms are already
  /// short and are left exactly as they render today.
  static const List<String> _enWeekdaysShort = [
    'Mon',
    'Tue',
    'Wed',
    'Thu',
    'Fri',
    'Sat',
    'Sun',
  ];

  /// A SINGLE-CHARACTER weekday label, for axes too narrow for a name.
  ///
  /// The daily-spend chart carried its own `const _initials` list of Arabic
  /// letters, so an English reader saw «ن ث ر خ ج س ح» under the bars with
  /// only "Today" in their language. A chart axis is the easiest place in an
  /// app for an untranslated string to hide: single characters read as
  /// decoration, and a string scan reports them as one-letter noise.
  ///
  /// English repeats T and S (Tue/Thu, Sat/Sun). That is the ordinary
  /// convention for a seven-slot axis and is what a reader expects; widening
  /// the axis to disambiguate would cost more than it buys.
  static String weekdayInitial(BuildContext context, DateTime d) =>
      Localizations.localeOf(context).languageCode == 'en'
          ? _enWeekdayInitials[d.weekday - 1]
          : _arWeekdayInitials[d.weekday - 1];

  /// `DateTime.monday` (1) → `sunday` (7).
  static const List<String> _arWeekdayInitials = [
    'ن', 'ث', 'ر', 'خ', 'ج', 'س', 'ح',
  ];
  static const List<String> _enWeekdayInitials = [
    'M', 'T', 'W', 'T', 'F', 'S', 'S',
  ];

  static String weekdayShort(BuildContext context, DateTime d) =>
      Localizations.localeOf(context).languageCode == 'en'
          ? _enWeekdaysShort[d.weekday - 1]
          : _arWeekdays[d.weekday - 1];

  /// "الثلاثاء، 21 مايو 2026" or "Tuesday, May 21, 2026"
  static String dateWithWeekday(DateTime dt, BuildContext context) {
    final d = dt.toLocal();
    final locale = Localizations.localeOf(context).languageCode;
    final weekday = locale == 'en'
        ? _enWeekdays[d.weekday - 1]
        : _arWeekdays[d.weekday - 1];
    final sep = locale == 'en' ? ', ' : '، ';
    return '$weekday$sep${fullDate(dt, context)}';
  }

  /// "8 أبريل 2026" or "April 8, 2026"
  static String fullDate(DateTime dt, BuildContext context) {
    final d = dt.toLocal();
    final locale = Localizations.localeOf(context).languageCode;
    if (locale == 'en') {
      return '${_enMonths[d.month - 1]} ${d.day}, ${d.year}';
    }
    return '${d.day} ${_arMonths[d.month - 1]} ${d.year}';
  }

  /// "أبريل 2026" or "April 2026"
  static String monthYear(DateTime dt, BuildContext context) {
    final d = dt.toLocal();
    final locale = Localizations.localeOf(context).languageCode;
    if (locale == 'en') {
      return '${_enMonths[d.month - 1]} ${d.year}';
    }
    return '${_arMonths[d.month - 1]} ${d.year}';
  }

  /// "12:45"
  static String time(DateTime dt) {
    final d = dt.toLocal();
    return '${_two(d.hour)}:${_two(d.minute)}';
  }

  /// عنوان مجموعة التاريخ: اليوم / أمس / "8 أبريل".
  static String dateGroupLabel(DateTime dt, BuildContext context) {
    final now = DateTime.now();
    final d = dt.toLocal();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(d.year, d.month, d.day);
    final diff = today.difference(that).inDays;

    final l10n = AppL10n.of(context);
    if (diff == 0) return l10n.today;
    if (diff == 1) return l10n.yesterday;

    final locale = Localizations.localeOf(context).languageCode;
    if (locale == 'en') {
      return '${_enMonths[d.month - 1]} ${d.day}';
    }
    return '${d.day} ${_arMonths[d.month - 1]}';
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// تحويل لون hex (#RRGGBB) إلى [Color].
  static Color colorFromHex(String hex) {
    var value = hex.replaceAll('#', '');
    if (value.length == 6) value = 'FF$value';
    return Color(int.parse(value, radix: 16));
  }
}
