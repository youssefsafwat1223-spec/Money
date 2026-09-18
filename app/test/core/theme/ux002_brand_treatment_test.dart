import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_colors.dart';

/// UX-002 — the hardcoded black/white treatment, fixed at its root.
///
/// The QA collected ~10 separate sightings (Budgets promo banner, Budgets and
/// Subscriptions and Goals tab pills, Settings theme selector, Transactions
/// filter chips, the primary button on Goal detail and Subscriptions…) and
/// stated the rule explicitly: **"one fix, not eight"**.
///
/// Every one of them resolved to a single token — `AppColors.ink` — so the fix
/// is a token change, not ten screen edits.
///
/// The finding's own constraints are the interesting part to test, because they
/// are what a careless "make it brand-coloured" pass would break: *"do NOT
/// blindly make everything blue. Preserve visual hierarchy, contrast,
/// accessibility, light/dark behaviour, and semantic states."*
double _relativeLuminance(Color c) {
  double channel(double v) {
    final s = v;
    return s <= 0.03928 ? s / 12.92 : math.pow((s + 0.055) / 1.055, 2.4) as double;
  }

  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

double _contrastRatio(Color a, Color b) {
  final la = _relativeLuminance(a);
  final lb = _relativeLuminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  group('the rejected grey-black treatment is still gone', () {
    // SUPERSEDED, 2026-09-18. This group used to assert
    // `AppColors.light.ink == AppBrandBlue.brand`, on the reading that UX-002
    // had settled the token forever. The owner has since made the design
    // prototype the authority for this treatment, and its `--ink-btn` is
    // #0B1024 — so that assertion was holding stale styling in place against a
    // newer instruction, and has been replaced rather than preserved.
    //
    // What UX-002 actually objected to survives here, because it is still
    // right: the rejected surface was #0F1115, a desaturated grey-black that
    // read as "not part of this product". #0B1024 is a NAVY — it carries the
    // brand's own hue, and it is measurably higher contrast than the value the
    // owner accepted in between. The finding's stated constraints (contrast,
    // hierarchy, light/dark behaviour, semantic states) are the assertions
    // below, and they are unchanged.
    test('ink is the design system\'s ink button', () {
      expect(AppColors.light.ink, const Color(0xFF0B1024),
          reason: 'the prototype\'s --ink-btn / --nav-bg');
    });

    test('ink is a navy, not the desaturated grey-black UX-002 rejected', () {
      // #0F1115 was essentially hueless: its blue channel led its red by 6/255.
      // The rejection was about that, not about darkness as such — the nav in
      // the design is darker still.
      final ink = AppColors.light.ink;
      final blueLead = ink.b - ink.r;
      expect(blueLead, greaterThan(0.06),
          reason: 'a hueless near-black is the treatment UX-002 rejected, '
              'whatever constant produced it');
    });
  });

  group('accessibility improved rather than degraded', () {
    test('onInk over ink beats WCAG AA for body text', () {
      final ratio = _contrastRatio(AppColors.light.onInk, AppColors.light.ink);
      expect(ratio, greaterThanOrEqualTo(4.5),
          reason: 'AA requires 4.5:1; got ${ratio.toStringAsFixed(2)}:1');
    });

    test('and beats AAA, as the previous near-black surface did', () {
      // The point is that the brand colour is not a contrast concession.
      final ratio = _contrastRatio(AppColors.light.onInk, AppColors.light.ink);
      expect(ratio, greaterThanOrEqualTo(7.0),
          reason: 'AAA requires 7:1; got ${ratio.toStringAsFixed(2)}:1');
    });

    test('dark theme keeps its own contrast', () {
      final ratio = _contrastRatio(AppColors.dark.onInk, AppColors.dark.ink);
      expect(ratio, greaterThanOrEqualTo(7.0));
    });
  });

  group('light/dark behaviour is preserved', () {
    test('dark ink stays the INVERTED (light) attention surface', () {
      // Painting dark-navy on a dark page would lose the contrast the light
      // theme just gained. The dark theme never had the black-surface defect.
      expect(_relativeLuminance(AppColors.dark.ink),
          greaterThan(_relativeLuminance(AppColors.light.ink)),
          reason: 'the treatment inverts between themes by design');
    });
  });

  group('semantic states are untouched', () {
    test('success / warning / danger / income / expense keep their hues', () {
      // "Do not blindly make everything blue" — the semantic colours carry
      // meaning and must not be absorbed into the brand.
      for (final entry in {
        'success': AppColors.light.success,
        'warning': AppColors.light.warning,
        'danger': AppColors.light.danger,
        'income': AppColors.light.income,
        'expense': AppColors.light.expense,
      }.entries) {
        expect(entry.value, isNot(AppBrandBlue.brand),
            reason: '${entry.key} must stay semantic, not become brand blue');
      }
    });
  });

  group('the sightings resolved to one token', () {
    test('the QA-cited surfaces all read ink rather than a literal', () {
      // If a screen re-introduces a hardcoded dark surface, this catches the
      // regression at the place the backlog said the fix belongs.
      for (final path in const [
        'lib/features/common/app_pill_tab_bar.dart',
        'lib/features/common/app_button.dart',
        'lib/features/budgets/budgets_screen.dart',
        'lib/features/transactions/transactions_screen.dart',
        'lib/features/settings/settings_screen.dart',
      ]) {
        final src = File(path).readAsStringSync();
        expect(src, contains('c.ink'),
            reason: '$path should take its attention surface from the token');
      }
    });
  });
}
