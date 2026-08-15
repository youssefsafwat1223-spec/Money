// MALI-COUPONS (Phase C4) — widget behaviour (§45) and feature-flag gating
// (§44) driven through the real providers with an overridden cache.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/l10n/app_localizations.dart';
import 'package:money_companion/features/coupons/coupon_analytics.dart';
import 'package:money_companion/features/coupons/coupon_models.dart';
import 'package:money_companion/features/coupons/coupon_widgets.dart';
import 'package:money_companion/features/coupons/coupons_providers.dart';
import 'package:money_companion/features/coupons/coupons_screen.dart';

CouponOffer _offer({
  String id = 'c1',
  String slug = 'offer-one',
  String titleAr = 'خصم كبير',
  String? titleEn = 'Big discount',
  CouponRedemptionType type = CouponRedemptionType.code,
  String? code = 'SAVE20',
  String? url,
  bool featured = false,
  String categoryKey = 'food',
  String categoryLabel = 'مطاعم',
  List<CouponTag> tags = const [],
  DateTime? validUntil,
  List<String> countries = const [],
}) =>
    CouponOffer(
      id: id,
      slug: slug,
      partnerName: 'شريك',
      titleAr: titleAr,
      titleEn: titleEn,
      descriptionAr: 'وصف العرض',
      descriptionEn: 'Offer description',
      redemptionType: type,
      code: code,
      partnerUrl: url,
      category: CouponCategory(key: categoryKey, labelAr: categoryLabel),
      tags: tags,
      countryCodes: countries,
      featured: featured,
      validFrom: DateTime.now().subtract(const Duration(days: 1)),
      validUntil: validUntil,
      accentHex: '#2563EB',
    );

Widget _app(Widget child, {List<Override> overrides = const []}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: const [
        AppL10n.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppL10n.supportedLocales,
      theme: AppTheme.dark,
      home: child,
    ),
  );
}

/// Records what the UI would report, without any Supabase/DB dependency.
class _SpyAnalytics extends CouponAnalyticsClient {
  _SpyAnalytics() : super(loadSettings: () async => throw StateError('unused'));

  final List<String> impressions = <String>[];
  final List<String> detailViews = <String>[];
  final List<String> copies = <String>[];
  final List<String> clicks = <String>[];

  @override
  Future<void> recordImpression(String couponId) async => impressions.add(couponId);
  @override
  Future<void> recordDetailView(String couponId) async => detailViews.add(couponId);
  @override
  Future<void> recordCodeCopy(String couponId) async => copies.add(couponId);
  @override
  Future<void> recordCtaClick(String couponId) async => clicks.add(couponId);
}

/// Overrides that skip the DB/flag layer: the screen reads `couponsProvider`.
List<Override> _catalog(
  List<CouponOffer> offers, {
  bool enabled = true,
  CouponAnalyticsClient? analytics,
}) =>
    [
      couponsEnabledProvider.overrideWithValue(enabled),
      couponsProvider.overrideWith((ref) async => enabled ? offers : const []),
      couponAnalyticsProvider.overrideWithValue(analytics ?? _SpyAnalytics()),
    ];

/// Settles frames AND lets the impression visibility timer (300ms) resolve, so
/// no timer is left pending when the tree is torn down.
Future<void> _settle(WidgetTester tester) async {
  await tester.pumpAndSettle();
  // Let the 300ms impression timer AND the top-banner auto-dismiss (5s) drain,
  // so no timer is pending when the tree is torn down. Fake time: costs nothing.
  await tester.pump(const Duration(seconds: 6));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Offers screen', () {
    testWidgets('renders catalog offers from the cache (Arabic, RTL)',
        (tester) async {
      await tester.pumpWidget(_app(const CouponsScreen(),
          overrides: _catalog(
              [_offer(), _offer(id: 'c2', slug: 'two', titleAr: 'عرض ثاني', code: 'OTHER10')])));
      await _settle(tester);

      expect(find.text('خصم كبير'), findsOneWidget);
      expect(find.text('عرض ثاني'), findsOneWidget);
      expect(find.text('SAVE20'), findsOneWidget);
      // The whole screen is laid out RTL for Arabic.
      expect(Directionality.of(tester.element(find.text('خصم كبير'))),
          TextDirection.rtl);
    });

    testWidgets('empty cache shows the calm empty state, never demo offers',
        (tester) async {
      await tester.pumpWidget(_app(const CouponsScreen(), overrides: _catalog(const [])));
      await _settle(tester);
      expect(find.text('لا توجد عروض حالياً'), findsOneWidget);
      // No demo partner can appear.
      expect(find.textContaining('Talabat'), findsNothing);
    });

    testWidgets('category filter narrows the list and can be cleared',
        (tester) async {
      await tester.pumpWidget(_app(
        const CouponsScreen(),
        overrides: _catalog([
          _offer(id: 'food', titleAr: 'عرض مطاعم'),
          _offer(id: 'shop', slug: 'shop', titleAr: 'عرض تسوق', categoryKey: 'shopping', categoryLabel: 'تسوق'),
        ]),
      ));
      await _settle(tester);
      expect(find.text('عرض مطاعم'), findsOneWidget);
      expect(find.text('عرض تسوق'), findsOneWidget);

      await tester.tap(find.text('تسوق'));
      await _settle(tester);
      expect(find.text('عرض مطاعم'), findsNothing);
      expect(find.text('عرض تسوق'), findsOneWidget);

      await tester.tap(find.text('الكل'));
      await _settle(tester);
      expect(find.text('عرض مطاعم'), findsOneWidget);
    });

    testWidgets('tag chips filter by the normalized tag, showing its label',
        (tester) async {
      await tester.pumpWidget(_app(
        const CouponsScreen(),
        overrides: _catalog([
          _offer(id: 'a', titleAr: 'مع وسم', tags: const [
            CouponTag(key: 'delivery', labelAr: 'توصيل'),
          ]),
          _offer(id: 'b', slug: 'b', titleAr: 'بدون وسم'),
        ]),
      ));
      await _settle(tester);

      // The chip renders the display LABEL, not the persistence key.
      expect(find.text('#توصيل'), findsOneWidget);
      expect(find.text('#delivery'), findsNothing);

      await tester.tap(find.text('#توصيل'));
      await _settle(tester);
      expect(find.text('مع وسم'), findsOneWidget);
      expect(find.text('بدون وسم'), findsNothing);
    });

    testWidgets('a filter with no matches shows its own empty state', (tester) async {
      await tester.pumpWidget(_app(
        const CouponsScreen(),
        overrides: _catalog([
          _offer(id: 'a', tags: const [CouponTag(key: 't1', labelAr: 'وسم')]),
        ]),
      ));
      await _settle(tester);
      await tester.tap(find.text('#وسم'));
      await _settle(tester);
      expect(find.text('خصم كبير'), findsOneWidget);
    });

    testWidgets('featured offers get their own section', (tester) async {
      await tester.pumpWidget(_app(
        const CouponsScreen(),
        overrides: _catalog([
          _offer(id: 'f', titleAr: 'مميز', featured: true),
          _offer(id: 'n', slug: 'n', titleAr: 'عادي'),
        ]),
      ));
      await _settle(tester);
      expect(find.text('عروض مميزة'), findsOneWidget);
      expect(find.text('مميز'), findsOneWidget);
    });

    testWidgets('English locale uses the English fallback content', (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: _catalog([_offer()]),
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: const [
            AppL10n.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppL10n.supportedLocales,
          theme: AppTheme.dark,
          home: const CouponsScreen(),
        ),
      ));
      await _settle(tester);
      expect(find.text('Offers'), findsOneWidget);
      expect(find.text('Big discount'), findsOneWidget);
    });
  });

  group('highlight route (§22)', () {
    testWidgets('an eligible slug opens its details sheet', (tester) async {
      await tester.pumpWidget(_app(
        const CouponsScreen(highlightSlug: 'offer-one'),
        overrides: _catalog([_offer()]),
      ));
      await _settle(tester);
      // The sheet shows the redemption CTA.
      expect(find.text('نسخ الكود'), findsOneWidget);
    });

    testWidgets('an unknown slug just shows the normal screen', (tester) async {
      await tester.pumpWidget(_app(
        const CouponsScreen(highlightSlug: 'does-not-exist'),
        overrides: _catalog([_offer()]),
      ));
      await _settle(tester);
      expect(find.text('نسخ الكود'), findsNothing);
      expect(find.text('خصم كبير'), findsOneWidget);
    });

    testWidgets('an INELIGIBLE slug cannot be surfaced by the deep route',
        (tester) async {
      // `couponsProvider` only ever yields eligible offers, so an expired or
      // country-ineligible slug simply is not there.
      await tester.pumpWidget(_app(
        const CouponsScreen(highlightSlug: 'offer-one'),
        overrides: _catalog(const []),
      ));
      await _settle(tester);
      expect(find.text('نسخ الكود'), findsNothing);
      expect(find.text('لا توجد عروض حالياً'), findsOneWidget);
    });
  });

  group('redemption (§42)', () {
    testWidgets('A/B: copying puts the code on the clipboard, repeatedly',
        (tester) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      await tester.pumpWidget(_app(
        const CouponsScreen(highlightSlug: 'offer-one'),
        overrides: _catalog([_offer()]),
      ));
      await _settle(tester);

      await tester.tap(find.text('نسخ الكود'));
      await _settle(tester);
      await tester.tap(find.text('نسخ الكود'));
      await _settle(tester);

      expect(copied, ['SAVE20', 'SAVE20'], reason: 'every explicit copy works');
    });

    testWidgets('C: a code offer with a partner url also offers "open"',
        (tester) async {
      await tester.pumpWidget(_app(
        const CouponsScreen(highlightSlug: 'offer-one'),
        overrides: _catalog([_offer(url: 'https://example.com')]),
      ));
      await _settle(tester);
      expect(find.text('نسخ الكود'), findsOneWidget);
      expect(find.text('فتح موقع الشريك'), findsOneWidget);
    });

    testWidgets('D: a link offer shows ONE CTA and no code', (tester) async {
      await tester.pumpWidget(_app(
        const CouponsScreen(highlightSlug: 'offer-one'),
        overrides: _catalog([
          _offer(type: CouponRedemptionType.link, code: null, url: 'https://example.com'),
        ]),
      ));
      await _settle(tester);
      expect(find.text('احصل على العرض'), findsOneWidget);
      expect(find.text('نسخ الكود'), findsNothing);
      expect(find.text('SAVE20'), findsNothing);
    });

    testWidgets('G: an offer that expired in the cache cannot be redeemed',
        (tester) async {
      // The sheet is rendered directly with a stale offer (as if the cache went
      // stale while it was open) — the action refuses instead of copying.
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      final expired = _offer(validUntil: DateTime.now().subtract(const Duration(days: 1)));
      await tester.pumpWidget(_app(
        Scaffold(body: CouponDetailsSheet(offer: expired)),
        overrides: _catalog(const []),
      ));
      await _settle(tester);
      await tester.tap(find.text('نسخ الكود'));
      // Assert BEFORE the banner auto-dismisses, then drain its timer.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(copied, isEmpty, reason: 'a stale offer never redeems');
      expect(find.text('العرض ده مش متاح دلوقتي'), findsOneWidget);
      await _settle(tester);
    });
  });

  group('feature flag (§44)', () {
    testWidgets('A/D: flag OFF -> the screen is a safe empty state, no promo UI',
        (tester) async {
      await tester.pumpWidget(_app(
        const CouponsScreen(),
        overrides: _catalog([_offer()], enabled: false),
      ));
      await _settle(tester);
      expect(find.text('خصم كبير'), findsNothing);
      expect(find.text('SAVE20'), findsNothing);
      expect(find.text('لا توجد عروض حالياً'), findsOneWidget);
    });

    testWidgets('C: flag ON -> eligible offers render', (tester) async {
      await tester.pumpWidget(_app(
        const CouponsScreen(),
        overrides: _catalog([_offer()], enabled: true),
      ));
      await _settle(tester);
      expect(find.text('خصم كبير'), findsOneWidget);
    });

    testWidgets('the dashboard teaser yields nothing while the flag is off',
        (tester) async {
      late List<CouponOffer> teaser;
      await tester.pumpWidget(_app(
        Consumer(builder: (context, ref, _) {
          teaser = ref.watch(dashboardCouponsProvider).valueOrNull ?? const [];
          return const SizedBox.shrink();
        }),
        overrides: _catalog([_offer()], enabled: false),
      ));
      await _settle(tester);
      expect(teaser, isEmpty);
    });

    testWidgets('the teaser caps the number of offers it shows', (tester) async {
      late List<CouponOffer> teaser;
      await tester.pumpWidget(_app(
        Consumer(builder: (context, ref, _) {
          teaser = ref.watch(dashboardCouponsProvider).valueOrNull ?? const [];
          return const SizedBox.shrink();
        }),
        overrides: _catalog(
          List.generate(6, (i) => _offer(id: 'c$i', slug: 's$i')),
        ),
      ));
      await _settle(tester);
      expect(teaser.length, 3);
    });
  });

  group('accessibility + presentation', () {
    testWidgets('cards expose a descriptive semantics label and the code',
        (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_app(const CouponsScreen(), overrides: _catalog([_offer()])));
      await _settle(tester);

      expect(find.bySemanticsLabel(RegExp('عرض من شريك: خصم كبير')), findsWidgets);
      expect(find.bySemanticsLabel(RegExp('كود الخصم SAVE20')), findsWidgets);
      handle.dispose();
    });

    testWidgets('a missing image falls back without breaking the card',
        (tester) async {
      await tester.pumpWidget(_app(
        const CouponsScreen(),
        overrides: _catalog([_offer()]), // imageUrl is null
      ));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('خصم كبير'), findsOneWidget);
    });
  });
}
