import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/utils/category_glyph.dart';
import 'package:money_companion/core/utils/category_icon.dart';
import 'package:money_companion/core/utils/category_tone.dart';
import 'package:money_companion/data/db/database_seed.dart';
import 'package:money_companion/engine/categorization/category.dart';

/// EVERY SHIPPING CATEGORY HAS A DESIGN GLYPH.
///
/// The category marks used to be native colour emoji. The design draws stroke
/// icons tinted with the category's ink, and the owner has made the design the
/// authority — so a category with no mapped icon is now a defect, not a
/// cosmetic gap. Without this test the failure mode is silent: one category
/// quietly renders the fallback shape and nobody notices until a user does.
void main() {
  test('every seeded category resolves to a real stroke icon', () {
    final unmapped = <String>[];
    for (final category in DatabaseSeed.categories) {
      if (categoryIconOrNull(category.icon) == null) {
        unmapped.add('${category.key} (icon "${category.icon}")');
      }
    }
    expect(unmapped, isEmpty,
        reason: 'these shipping categories have no design glyph and would fall '
            'back: ${unmapped.join(", ")}. Add them to category_icon.dart.');
  });

  test('every category in the engine catalogue is covered, smoking included',
      () {
    // `Categories.all` is what the parser and the categoriser work from; the
    // seed derives its icons from it. Both are checked because a key can exist
    // in one and not reach the other.
    final seeded = {for (final c in DatabaseSeed.categories) c.key: c.icon};
    final missing = <String>[];
    for (final category in Categories.all) {
      final icon = seeded[category.key];
      if (icon == null) {
        missing.add('${category.key}: not seeded');
      } else if (categoryIconOrNull(icon) == null) {
        missing.add('${category.key}: icon "$icon" unmapped');
      }
    }
    expect(missing, isEmpty, reason: missing.join(', '));

    // Named explicitly because the brief named it.
    final smokingIcon = seeded[Categories.smoking.key];
    expect(smokingIcon, isNotNull);
    expect(categoryIconOrNull(smokingIcon!), isNotNull,
        reason: 'the smoking/tobacco category must have a design glyph');
  });

  test('no mapped name resolves to the fallback by accident', () {
    // A typo'd map entry would still "resolve" — to whatever the fallback is.
    // This catches an entry that silently points at the generic shape.
    final suspicious = <String>[];
    for (final name in mappedCategoryIconNames) {
      if (name == 'shapes') continue; // the one legitimate use
      if (categoryIconOrNull(name) == fallbackCategoryIcon) {
        suspicious.add(name);
      }
    }
    expect(suspicious, isEmpty,
        reason: 'these map to the generic fallback glyph: '
            '${suspicious.join(", ")}');
  });

  testWidgets('the glyph renders an Icon, never emoji text', (tester) async {
    // The regression this file exists for: a Text-rendered emoji cannot take
    // the category tint and is a different visual language from the design.
    for (final category in DatabaseSeed.categories.take(6)) {
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.rtl,
        child: CategoryGlyph(
          name: category.icon,
          size: 24,
          color: const Color(0xFFE8763A),
        ),
      ));
      expect(find.byType(Icon), findsOneWidget,
          reason: '${category.key} did not render a stroke icon');
      expect(find.byType(Text), findsNothing,
          reason: '${category.key} still renders text/emoji');
      expect(tester.widget<Icon>(find.byType(Icon)).color,
          const Color(0xFFE8763A),
          reason: '${category.key} ignored the category tint');
    }
  });

  test('every category has a legible tone pair in BOTH themes', () {
    // The regression this catches, found on device: a single category colour
    // at 12% alpha looked right on white and was invisible on black. The
    // design's answer is a PAIR per theme — dark lightens the ink and darkens
    // the ground — so both are asserted to actually separate.
    double luminance(Color c) {
      double ch(double v) =>
          v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4) as double;
      return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
    }

    double contrast(Color a, Color b) {
      final la = luminance(a), lb = luminance(b);
      final hi = math.max(la, lb), lo = math.min(la, lb);
      return (hi + 0.05) / (lo + 0.05);
    }

    final weak = <String>[];
    for (final category in DatabaseSeed.categories) {
      for (final brightness in Brightness.values) {
        final tone = categoryTone(category.icon, brightness);
        final ratio = contrast(tone.ink, tone.background);
        // 3:1 — the WCAG threshold for non-text graphics, which is what a
        // glyph on its own tile is.
        if (ratio < 3.0) {
          weak.add('${category.key} ${brightness.name}: '
              '${ratio.toStringAsFixed(2)}:1');
        }
      }
    }
    expect(weak, isEmpty,
        reason: 'these category glyphs are not legible on their own tile: '
            '${weak.join(", ")}');
  });

  test('dark mode lightens the ink rather than reusing the light one', () {
    // If dark simply reused the light pair, the ink would be darker than its
    // own background on a dark ground — the failure that was on screen.
    for (final icon in const [
      'utensils-crossed',
      'car-taxi-front',
      'receipt-text',
      'shopping-bag',
      'banknote',
      'shapes',
    ]) {
      final light = categoryTone(icon, Brightness.light);
      final dark = categoryTone(icon, Brightness.dark);
      expect(dark.ink, isNot(light.ink), reason: '$icon reused its light ink');
      expect(dark.background, isNot(light.background),
          reason: '$icon reused its light ground');
    }
  });

  testWidgets('only the transfer arrow mirrors in RTL', (tester) async {
    expect(categoryIconMirrors('arrow-left-right'), isTrue,
        reason: 'a transfer arrow points the wrong way unmirrored in Arabic');
    for (final name in const ['coffee', 'plane', 'cigarette', 'fuel']) {
      expect(categoryIconMirrors(name), isFalse,
          reason: '$name is an object; objects do not flip');
    }

    await tester.pumpWidget(const Directionality(
      textDirection: TextDirection.rtl,
      child: CategoryGlyph(name: 'arrow-left-right', size: 24),
    ));
    expect(tester.widget<Icon>(find.byType(Icon)).textDirection,
        TextDirection.rtl);

    await tester.pumpWidget(const Directionality(
      textDirection: TextDirection.rtl,
      child: CategoryGlyph(name: 'coffee', size: 24),
    ));
    expect(tester.widget<Icon>(find.byType(Icon)).textDirection,
        TextDirection.ltr);
  });
}
