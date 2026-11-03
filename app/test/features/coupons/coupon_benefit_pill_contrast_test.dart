// Actual public benefit text contrast and unchanged value/fill contract.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:money_companion/core/theme/app_typography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/app_colors.dart';
import 'package:money_companion/features/cards/brand_mark.dart';
import 'package:money_companion/features/coupons/coupon_models.dart';
import 'package:money_companion/features/coupons/coupon_value.dart';
import 'package:money_companion/features/coupons/coupon_widgets.dart';
import 'package:money_companion/l10n/app_localizations.dart';

void main() {
  final measurements = <Map<String, Object?>>[];
  for (final language in ['ar', 'en']) {
    for (final dark in [false, true]) {
      testWidgets('observe actual benefitpill $language dark=$dark',
          (tester) async {
        tester.view.physicalSize = const Size(375, 667);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.runAsync(() async {
          final font = FontLoader('Vazirmatn');
          for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
            font.addFont(rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
          }
          await font.load();
        });
        var httpCalls = 0;
        await HttpOverrides.runZoned(() async {
          final offer = CouponOffer(
              id: 'qa-benefit',
              slug: 'qa-benefit',
              partnerName: 'QA unknown',
              titleAr: 'عرض',
              titleEn: 'Offer',
              descriptionAr: 'تفاصيل',
              redemptionType: CouponRedemptionType.code,
              code: 'SAVE20',
              category: const CouponCategory(key: 'food', labelAr: 'مطاعم'),
              validFrom: DateTime.utc(2026),
              benefitType: 'percent',
              discountBps: 2000,
              benefitCurrency: 'EGP');
          await tester.pumpWidget(ProviderScope(
              overrides: [
                remoteMerchantLogosAllowedProvider.overrideWithValue(false)
              ],
              child: MaterialApp(
                  theme: dark ? AppTheme.dark : AppTheme.light,
                  locale: Locale(language),
                  supportedLocales: AppL10n.supportedLocales,
                  localizationsDelegates: AppL10n.localizationsDelegates,
                  home:
                      Scaffold(body: CouponCard(offer: offer, onTap: () {})))));
          await tester.pumpAndSettle();
          final context = tester.element(find.byType(CouponCard));
          final l10n = AppL10n.of(context);
          final text = CouponValueLabel.headline(offer, l10n)!;
          final finder = find.text(text);
          expect(finder, findsOneWidget);
          final ink =
              tester.renderObject<RenderParagraph>(finder).text.style!.color!;
          Color? fill;
          tester.element(finder).visitAncestorElements((e) {
            if (e.widget
                case DecoratedBox(decoration: final BoxDecoration box)) {
              if (box.color != null) {
                fill = box.color;
                return false;
              }
            }
            return true;
          });
          final c = context.colors;
          final composed = Color.alphaBlend(fill!, c.surfaceCard);
          final a = Color.alphaBlend(ink, composed).computeLuminance(),
              z = composed.computeLuminance();
          final ratio = (math.max(a, z) + .05) / (math.min(a, z) + .05);
          measurements.add({
            'language': language,
            'dark': dark,
            'text': text,
            'foregroundArgb': ink.toARGB32(),
            'fillArgb': fill!.toARGB32(),
            'surfaceCardArgb': c.surfaceCard.toARGB32(),
            'composedFillArgb': composed.toARGB32(),
            'actualContrast': ratio,
            'httpClientAttempts': httpCalls,
            'passes4_5': ratio >= 4.5
          });
          final evidenceDirectory =
              Directory.systemTemp.createTempSync('qirsh-test-evidence-');
          addTearDown(() => evidenceDirectory.deleteSync(recursive: true));
          File('${evidenceDirectory.path}/coupon-benefit-pill-current-paint.json')
              .writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
            'qualification':
                'Actual public CouponCard RenderParagraph and nearestBoxDecoration fill composited over actual c.surfaceCard. QAonly syntheticoffer;remoteproviderfalsefixture, noaction/transport. Strict actual contrast gate; no other value/layout/paint changed.',
            'measurements': measurements
          }));
          expect(ink, dark ? c.textPrimary : c.cta);
          final label = tester.widget<Text>(finder);
          expect(label.data, text);
          expect(label.style,
              AppTypography.caption(ink).copyWith(fontWeight: FontWeight.w700));
          expect(offer.discountBps, 2000);
          expect(offer.benefitCurrency, 'EGP');
          expect(find.byType(Image), findsNothing);
          expect(httpCalls, 0);
          expect(fill, c.cta.withValues(alpha: .1));
          expect(tester.takeException(), isNull);
          expect(ratio, greaterThanOrEqualTo(4.5));
        }, createHttpClient: (context) {
          httpCalls++;
          throw StateError(
              'benefit pure fixture cannot construct network client');
        });
      });
    }
  }
}
