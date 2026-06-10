import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

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

  /// "45.00"
  static String amount(double value) => _money.format(value);

  /// "1,240"
  static String integer(num value) => _int.format(value);

  /// مبلغ بإشارة: مصروف بالسالب، دخل/استرداد بالموجب.
  static String signed(double value, {required bool isExpense}) {
    final formatted = _money.format(value.abs());
    return isExpense ? '−$formatted' : '+$formatted';
  }

  /// "8 أبريل 2026"
  static String fullDate(DateTime dt) {
    final d = dt.toLocal();
    return '${d.day} ${_arMonths[d.month - 1]} ${d.year}';
  }

  /// "12:45"
  static String time(DateTime dt) {
    final d = dt.toLocal();
    return '${_two(d.hour)}:${_two(d.minute)}';
  }

  /// عنوان مجموعة التاريخ: اليوم / أمس / "8 أبريل".
  static String dateGroupLabel(DateTime dt) {
    final now = DateTime.now();
    final d = dt.toLocal();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(d.year, d.month, d.day);
    final diff = today.difference(that).inDays;
    if (diff == 0) return 'اليوم';
    if (diff == 1) return 'أمس';
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
