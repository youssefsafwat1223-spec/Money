import 'package:flutter/widgets.dart';

import '../../core/utils/l10n_ext.dart';

/// A card theme's name in the reader's language.
///
/// `kCardThemes` is a `const` catalog — it cannot hold localized copy — so the
/// theme carries its stable `key` and the words live in the ARB. An unknown key
/// falls back to whatever the catalog stored, which is Arabic and visible.
String cardThemeLabel(BuildContext context, String key, String fallback) {
  final l = context.l10n;
  return switch (key) {
    'navy' => l.cardThemeNavy,
    'emerald' => l.cardThemeEmerald,
    'plum' => l.cardThemePlum,
    'sunset' => l.cardThemeSunset,
    'graphite' => l.cardThemeGraphite,
    'ocean' => l.cardThemeOcean,
    _ => fallback,
  };
}
