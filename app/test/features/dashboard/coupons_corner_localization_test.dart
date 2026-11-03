import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/directional_chevron.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/features/coupons/coupon_models.dart';
import 'package:money_companion/features/dashboard/widgets/coupons_corner.dart';
import 'package:money_companion/l10n/app_localizations.dart';

void main() {
  for (final language in ['en', 'ar']) {
    testWidgets('offer count follows $language and preserves offer taps', (tester) async {
      for (final count in [1, 2, 3, 11]) {
        CouponOffer? opened;
        final offers = List.generate(count, (index) => CouponOffer(
          id: '$index', slug: 'test-$index', partnerName: 'Partner',
          titleAr: 'عرض', titleEn: 'Offer', descriptionAr: 'تفاصيل',
          redemptionType: count == 1 ? CouponRedemptionType.link : CouponRedemptionType.code,
          code: count == 1 ? null : 'SAVE',
          partnerUrl: count == 1 ? 'https://example.com/offer' : null,
          category: const CouponCategory(key: 'food', labelAr: 'مطاعم'),
          validFrom: DateTime(2026),
        ));
        await tester.pumpWidget(ProviderScope(overrides: [
          merchantLogosProvider.overrideWith((ref) async => const {}),
        ], child: MaterialApp(
          theme: AppTheme.light, locale: Locale(language),
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: Scaffold(body: SingleChildScrollView(child: CouponsCorner(
            offers: offers, preferEnglish: language == 'en',
            onOpen: (offer) => opened = offer,
          ))),
        )));
        await tester.pumpAndSettle();
        final context = tester.element(find.byType(CouponsCorner));
        expect(find.text(AppL10n.of(context).homeAvailableCoupons(count)), findsOneWidget);
        if (language == 'en') {
          expect(find.text('$count coupons available'), count == 1 ? findsNothing : findsOneWidget);
          expect(find.text('1 coupon available'), count == 1 ? findsOneWidget : findsNothing);
        }
        expect(find.byType(DirectionalChevron), count == 1 ? findsOneWidget : findsNothing);
        await tester.tap(find.text(language == 'en' ? 'Offer' : 'عرض').first);
        expect(opened, same(offers.first));
        expect(tester.takeException(), isNull);
      }
    });
  }
}
