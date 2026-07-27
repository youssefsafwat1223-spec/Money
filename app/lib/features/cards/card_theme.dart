import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// خيار ثيم تصميم البطاقة: مفتاح ثابت (يُخزَّن على البطاقة) + تسمية + تدرّج.
/// الألوان مُنتقاة لتُقرأ جيدًا مع نص أبيض (النهاية أغمق دائمًا).
class CardThemeOption {
  const CardThemeOption(this.key, this.label, this.colors);

  final String key;
  final String label;
  final List<Color> colors; // [البداية، النهاية]
}

/// كتالوج ثيمات البطاقة المنسّق — نظام تصميم واحد، لا فوضى ألوان.
const List<CardThemeOption> kCardThemes = <CardThemeOption>[
  CardThemeOption('navy', 'كحلي', [Color(0xFF3A7BD5), Color(0xFF00185E)]),
  CardThemeOption('emerald', 'زمرّدي', [Color(0xFF34D399), Color(0xFF065F46)]),
  CardThemeOption('plum', 'برقوقي', [Color(0xFFB06AB3), Color(0xFF3B1C5A)]),
  CardThemeOption('sunset', 'غروب', [Color(0xFFFF8A5B), Color(0xFFB0273A)]),
  CardThemeOption('graphite', 'جرافيت', [Color(0xFF4B5563), Color(0xFF111827)]),
  CardThemeOption('ocean', 'محيط', [Color(0xFF2BC0E4), Color(0xFF12507B)]),
];

/// لوحة ألوان مميّزة منسّقة (اختيارية) — hex فقط، بلا اعتماد على أي مكتبة.
const List<String> kCardAccentSwatches = <String>[
  '#F59E0B',
  '#EF4444',
  '#EC4899',
  '#8B5CF6',
  '#3B82F6',
  '#06B6D4',
  '#10B981',
  '#84CC16',
  '#F97316',
  '#14B8A6',
];

/// يعيد خيار الثيم بمفتاحه، أو null (الثيم الافتراضي) إن لم يُطابق.
CardThemeOption? cardThemeByKey(String? key) {
  if (key == null) return null;
  for (final theme in kCardThemes) {
    if (theme.key == key) return theme;
  }
  return null;
}

/// يحوّل نص hex (‎#RRGGBB أو RRGGBB أو AARRGGBB) إلى Color، أو null.
Color? parseAccent(String? hex) {
  if (hex == null) return null;
  var h = hex.trim();
  if (h.startsWith('#')) h = h.substring(1);
  if (h.length == 6) h = 'FF$h';
  if (h.length != 8) return null;
  final value = int.tryParse(h, radix: 16);
  return value == null ? null : Color(value);
}

/// تدرّج البطاقة النهائي: الثيم الافتراضي (بلا مفتاح) = `primaryGradient`؛ ثيم
/// منسّق = تدرّجه؛ ولون مميّز اختياري يطغى على لون النهاية فيظهر تخصيص المستخدم.
Gradient cardGradient(
  BuildContext context, {
  String? themeKey,
  String? accentHex,
}) {
  final accent = parseAccent(accentHex);
  final preset = cardThemeByKey(themeKey);
  if (preset == null) {
    final base = context.colors.primaryGradient;
    if (accent == null) return base;
    return LinearGradient(
      begin: base.begin,
      end: base.end,
      colors: [base.colors.first, accent],
    );
  }
  return LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: accent == null ? preset.colors : [preset.colors.first, accent],
  );
}
