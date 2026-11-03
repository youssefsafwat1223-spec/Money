import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/app_typography.dart';
import 'package:money_companion/core/theme/widgets/calm_page_header.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/finance/money_format.dart';
import 'package:money_companion/l10n/app_localizations.dart';

Future<void> _fonts(WidgetTester tester) async {
  await tester.runAsync(() async {
    final fonts = FontLoader('Vazirmatn');
    for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      fonts.addFont(rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
    }
    await fonts.load();
  });
}

Future<void> _open(WidgetTester tester, double width, String language,
    bool dark, double textScale, List<CalmMetric> metrics,
    {EdgeInsetsGeometry margin = const EdgeInsets.symmetric(horizontal: 16)}) async {
  tester.view.physicalSize = Size(width, 874);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await _fonts(tester);
  await tester.pumpWidget(MaterialApp(
    theme: dark ? AppTheme.dark : AppTheme.light,
    locale: Locale(language), supportedLocales: AppL10n.supportedLocales,
    localizationsDelegates: AppL10n.localizationsDelegates,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!),
    home: Scaffold(body: SingleChildScrollView(child: CalmKpiTiles(metrics: metrics, margin: margin))),
  ));
  await tester.pumpAndSettle();
}

double _paintScale(RenderParagraph paragraph) {
  final transform = paragraph.getTransformTo(null).storage;
  return math.sqrt(transform[0] * transform[0] + transform[1] * transform[1]);
}

void _expectReadableGlyphs(WidgetTester tester, String value, double width) {
  final finder = find.text(value);
  expect(finder, findsOneWidget);
  final paragraph = tester.renderObject<RenderParagraph>(finder);
  expect(_paintScale(paragraph), greaterThanOrEqualTo(.8 - .001),
      reason: 'Render transforms must retain at least 80% of the original text size; '
          'an unscaled Text rect does not prove readable FittedBox output.');
  expect(paragraph.didExceedMaxLines, isFalse);
  final transform = paragraph.getTransformTo(null);
  final glyphs = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: 0, extentOffset: value.length));
  expect(glyphs, isNotEmpty);
  for (final glyph in glyphs) {
    final painted = MatrixUtils.transformRect(transform, glyph.toRect());
    expect(painted.left, greaterThanOrEqualTo(-.01));
    expect(painted.right, lessThanOrEqualTo(width + .01));
    expect(painted.top, greaterThanOrEqualTo(-.01));
    expect(painted.bottom, lessThanOrEqualTo(874));
  }
}

void main() {
  testWidgets('dark KPI border cannot reduce a near-threshold value below the readable scale', (tester) async {
    await _fonts(tester);
    const value = '12345678';
    final painter = TextPainter(text: TextSpan(text: value,
      style: AppTypography.custom(size: 17, weight: FontWeight.w700,
        height: 1.25, tabular: true, color: Colors.white)),
      textDirection: TextDirection.ltr)..layout();
    final naturalWidth = painter.width;
    painter.dispose();
    // Size a real custom-margin three-column grid close to the readability
    // boundary. The dark tile's painted border consumes two more pixels.
    final margin = (375 - 16 - 3 * (naturalWidth * .805 + 24)) / 2;
    expect(margin, greaterThan(0));
    await _open(tester, 375, 'en', true, 1, const [
      CalmMetric(label: 'First', value: '1'),
      CalmMetric(label: 'Second', value: '2'),
      CalmMetric(label: 'Exact count', value: value),
    ], margin: EdgeInsets.symmetric(horizontal: margin));
    _expectReadableGlyphs(tester, value, 375);
    expect(tester.takeException(), isNull);
  });

  for (final width in [375.0, 402.0]) {
    for (final language in ['ar', 'en']) {
      for (final dark in [false, true]) {
        for (final textScale in [1.0, 1.9411764705882353]) {
          testWidgets('canonical KPI stays readable at${width.toInt()} $language dark$dark scale$textScale', (tester) async {
            final currency = language == 'ar' ? 'دينار' : 'KWD';
            final yearly = '${formatMoney(Money(9007199254740993, 'KWD') * 12)} $currency';
            final labels = language == 'ar'
                ? ['اشتراك نشط', 'قسط جارٍ', 'الإجمالي السنوي']
                : ['Active subscription', 'Running instalment', 'Yearly total'];
            await _open(tester, width, language, dark, textScale, [
              CalmMetric(label: labels[0], value: '1'),
              CalmMetric(label: labels[1], value: '2'),
              CalmMetric(label: labels[2], value: yearly),
            ]);
            _expectReadableGlyphs(tester, yearly, width);
            final annualRect = tester.getRect(find.ancestor(of: find.text(labels[2]),
                matching: find.byType(Container)).first);
            expect(annualRect.width, closeTo(width - 32, .01),
                reason: 'The long value needs the full tile row, not tiny text in one of three columns.');
            if (textScale > 1.5) {
              final paragraph = tester.renderObject<RenderParagraph>(find.text(yearly));
              final lines = paragraph.getBoxesForSelection(TextSelection(
                  baseOffset: 0, extentOffset: yearly.length)).map((box) => box.top).toSet();
              expect(lines.length, greaterThan(1),
                  reason: 'An accessible value wider than the full row wraps at its natural size.');
            }
            for (final label in labels) {
              expect(find.text(label), findsOneWidget);
            }
            expect(tester.takeException(), isNull);
          });
        }

        testWidgets('ordinary KPI retains equal three columns and two-plus-two at${width.toInt()} $language dark$dark', (tester) async {
          for (final count in [3, 4]) {
            final metrics = [for (var i = 0; i < count; i++)
              CalmMetric(label: 'Metric $i', value: '${(i + 1) * 100}')];
            await _open(tester, width, language, dark, 1, metrics);
            final perRow = count == 3 ? 3 : 2;
            final expectedWidth = (width - 32 - (perRow - 1) * 8) / perRow;
            final tiles = [for (var i = 0; i < count; i++)
              tester.getRect(find.ancestor(of: find.text('Metric $i'),
                  matching: find.byType(Container)).first)];
            for (var i = 0; i < count; i++) {
              expect(tiles[i].width, closeTo(expectedWidth, .01));
              _expectReadableGlyphs(tester, metrics[i].value, width);
              if (i % perRow != 0) {
                expect(tiles[i].top, tiles[i - 1].top);
                expect(language == 'ar' ? tiles[i].left < tiles[i - 1].left
                    : tiles[i].left > tiles[i - 1].left, isTrue);
              } else if (i > 0) {
                expect(tiles[i].top, greaterThan(tiles[i - 1].bottom));
              }
            }
            expect(tester.takeException(), isNull);
          }
        });
      }
    }
  }
}
