import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_colors.dart';

/// WCAG contrast on the REAL token pairs.
///
/// ## Why this exists rather than trusting the automated audit
///
/// `integration_test/accessibility_audit_test.dart` reported contrast failing
/// on 10/10 routes. Flutter's `textContrastGuideline` samples the pixels behind
/// the text, and this app puts white text on navy gradients across most
/// headers — a case the matcher is known to misreport. Taking that result at
/// face value would have meant "change the brand palette", weeks of work, for a
/// defect that mostly was not there.
///
/// Computing the ratio directly settled it. White on the navy headers measures
/// **13.36:1** and **10.36:1** — nowhere near a failure. Body text on its real
/// surface measures 17.74:1. The automated result was dominated by false
/// positives, and the genuine problems were somewhere else entirely:
/// `textMuted`, at 3.63:1 in light and 4.05:1 in dark, used for captions,
/// hints and subtitles across 38 files.
///
/// Those two tokens were adjusted — hue preserved, lightness moved just far
/// enough — and this test is what keeps them there.
///
/// ## What is deliberately NOT asserted
///
/// * `disabledFg` (3.05:1). WCAG 2.1 SC 1.4.3 explicitly exempts text that is
///   part of an inactive control. Raising it would make disabled look enabled,
///   which is a usability regression traded for a number.
/// * `warning` as a foreground (3.19:1 on white). Its uses are badge fills and
///   icon tints — UI components, which SC 1.4.11 holds to 3:1, not text.
double _luminance(Color c) {
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) +
      0.7152 * channel(c.g) +
      0.0722 * channel(c.b);
}

double contrast(Color fg, Color bg) {
  final a = _luminance(fg);
  final b = _luminance(bg);
  return (math.max(a, b) + 0.05) / (math.min(a, b) + 0.05);
}

void main() {
  const aaNormal = 4.5;

  const light = AppColors.light;
  const dark = AppColors.dark;

  group('AA for normal-size text on the pairs the app actually renders', () {
    final pairs = <String, List<Color>>{
      'light textPrimary on surface': [light.textPrimary, light.surface],
      'light textPrimary on bg': [light.textPrimary, light.bg],
      'light textSecondary on surface': [light.textSecondary, light.surface],
      'light textMuted on surface': [light.textMuted, light.surface],
      'light textMuted on bg': [light.textMuted, light.bg],
      'light neutral on surface': [light.neutral, light.surface],
      'light onWarning on warningBg': [light.onWarning, light.warningBg],
      'dark textPrimary on surface': [dark.textPrimary, dark.surface],
      'dark textPrimary on bg': [dark.textPrimary, dark.bg],
      'dark textMuted on surface': [dark.textMuted, dark.surface],
      'dark ink on surface': [dark.ink, dark.surface],
    };

    pairs.forEach((name, cs) {
      test(name, () {
        final r = contrast(cs[0], cs[1]);
        expect(r, greaterThanOrEqualTo(aaNormal),
            reason: '$name is ${r.toStringAsFixed(2)}:1, below AA ($aaNormal)');
      });
    });
  });

  test('white on the navy headers was never the problem', () {
    // The pair the automated matcher flagged on every route. Asserted so the
    // record shows what was actually measured rather than what was reported.
    for (final navy in const [Color(0xFF0B2B6B), Color(0xFF1E3A8A)]) {
      final r = contrast(const Color(0xFFFFFFFF), navy);
      expect(r, greaterThan(10.0),
          reason: 'white on $navy measured ${r.toStringAsFixed(2)}:1');
    }
  });
}
