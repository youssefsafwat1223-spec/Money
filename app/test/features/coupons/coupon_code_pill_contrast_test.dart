import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_colors.dart';
import 'package:money_companion/core/theme/app_spacing.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/app_typography.dart';
import 'package:money_companion/features/coupons/coupon_widgets.dart';
import 'package:money_companion/l10n/app_localizations.dart';

void main() {
  for (final language in ['ar', 'en']) {
    for (final dark in [false, true]) {
      testWidgets('actual coupon code pill paint $language dark=$dark',
          (tester) async {
        var httpCalls = 0;
        await HttpOverrides.runZoned(() async {
          tester.view.physicalSize = const Size(375, 667);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.runAsync(() async {
            final font = FontLoader('Vazirmatn');
            for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
              font.addFont(
                  rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
            }
            await font.load();
          });
          const code = 'QIRSH20';
          await tester.pumpWidget(MaterialApp(
              theme: dark ? AppTheme.dark : AppTheme.light,
              locale: Locale(language),
              supportedLocales: AppL10n.supportedLocales,
              localizationsDelegates: AppL10n.localizationsDelegates,
              home: const Scaffold(
                  body: Center(child: CouponCodePill(code: code)))));
          await tester.pumpAndSettle();
          final pill = find.byType(CouponCodePill), label = find.text(code);
          final context = tester.element(pill);
          final c = context.colors;
          final container = tester.widget<Container>(
              find.descendant(of: pill, matching: find.byType(Container)));
          final decoration = container.decoration! as BoxDecoration;
          final paragraph = tester.renderObject<RenderParagraph>(label);
          final text = tester.widget<Text>(label);
          final foreground = paragraph.text.style!.color!;
          final surface = tester
              .widgetList<Material>(
                  find.ancestor(of: pill, matching: find.byType(Material)))
              .firstWhere((material) => material.color?.a == 1)
              .color!;
          final fill = Color.alphaBlend(decoration.color!, surface);
          final paint = Color.alphaBlend(foreground, fill);
          final a = paint.computeLuminance(), b = fill.computeLuminance();
          final contrast = (math.max(a, b) + .05) / (math.min(a, b) + .05);
          expect(decoration.color, c.ctaSoft);
          expect(decoration.border,
              Border.all(color: c.cta.withValues(alpha: .18)));
          expect(
              decoration.borderRadius, BorderRadius.circular(AppRadius.pill));
          expect(container.padding,
              const EdgeInsets.symmetric(horizontal: 10, vertical: 8));
          expect(text.data, code);
          expect(text.textDirection, TextDirection.ltr);
          expect(text.maxLines, 1);
          expect(text.overflow, TextOverflow.ellipsis);
          final expectedStyle = AppTypography.caption(foreground)
              .copyWith(fontWeight: FontWeight.w700, letterSpacing: .5);
          expect(text.style, expectedStyle);
          expect(paragraph.didExceedMaxLines, isFalse);
          final semantics = tester.widget<Semantics>(
              find.descendant(of: pill, matching: find.byType(Semantics)));
          expect(semantics.properties.label,
              AppL10n.of(context).couponsCodeSemantics(code));
          expect(semantics.properties.onTap, isNull);
          expect(find.byType(Image), findsNothing);
          expect(find.byType(EditableText), findsNothing);
          expect(find.byType(TextButton), findsNothing);
          expect(tester.getRect(pill).left, greaterThanOrEqualTo(0));
          expect(tester.getRect(pill).right, lessThanOrEqualTo(375));
          expect(foreground, dark ? c.textPrimary : c.primary,
              reason: 'Only text uses existing readable theme tokens');
          expect(httpCalls, 0);
          expect(tester.takeException(), isNull);
          debugPrint(
              'Coupon code $language dark=$dark foreground=$foreground fill=$fill ratio=$contrast');
          expect(contrast, greaterThanOrEqualTo(4.5));
        }, createHttpClient: (context) {
          httpCalls++;
          throw StateError('pure coupon pill cannot construct network client');
        });
      });
    }
  }
}
