import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/data/catalog/catalog_daos.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/coupons/affiliate_click_gateway.dart';
import 'package:money_companion/features/coupons/coupon_analytics.dart';
import 'package:money_companion/features/coupons/coupon_models.dart';
import 'package:money_companion/features/coupons/coupon_widgets.dart';
import 'package:money_companion/features/coupons/coupons_providers.dart';
import 'package:money_companion/features/settings/settings_providers.dart';
import 'package:money_companion/l10n/app_localizations.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
// Transitive by design: these tests assert at the PLATFORM boundary, which is
// the only place a launch can be observed without trusting the widget.
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/link.dart';
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

/// BEHAVIOURAL CTA tests: a real widget, a real tap, a real launcher boundary.
///
/// These replace source-text guards, which could pass while the CTA still
/// launched `offer.partnerUrl` — the expected symbol names merely had to appear
/// somewhere in the file. Here the only thing asserted is what actually reached
/// the platform launcher.
class _RecordingLauncher extends UrlLauncherPlatform
    with MockPlatformInterfaceMixin {
  final List<String> launched = <String>[];

  @override
  Widget Function(LinkInfo)? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add(url);
    return true;
  }

  @override
  Future<bool> launch(
    String url, {
    required bool useSafariVC,
    required bool useWebView,
    required bool enableJavaScript,
    required bool enableDomStorage,
    required bool universalLinksOnly,
    required Map<String, String> headers,
    String? webOnlyWindowName,
  }) async {
    launched.add(url);
    return true;
  }
}

/// A gateway stub that returns exactly what a test wants the CTA to receive.
class _StubGateway implements AffiliateClickGateway {
  _StubGateway(this._result);
  final ClickResult _result;
  var opens = 0;

  @override
  Future<ClickResult> open(CouponOffer offer,
      {String surface = 'unknown'}) async {
    opens++;
    return _result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

CouponOffer _offer({String? url = 'https://merchant.example/deal'}) =>
    CouponOffer(
      id: 'o1',
      slug: 'deal',
      partnerName: 'شريك',
      titleAr: 'عرض',
      titleEn: 'Offer',
      descriptionAr: 'وصف',
      descriptionEn: 'Description',
      redemptionType: CouponRedemptionType.link,
      code: null,
      partnerUrl: url,
      category: const CouponCategory(key: 'food', labelAr: 'طعام'),
      tags: const [],
      countryCodes: const ['SA'],
      featured: false,
      validFrom: DateTime.now().subtract(const Duration(days: 1)),
      validUntil: DateTime.now().add(const Duration(days: 30)),
      accentHex: '#2563EB',
    );

Widget _app(Widget child, {List<Override> overrides = const []}) =>
    ProviderScope(
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
        // The failure paths surface a banner, which needs a Scaffold ancestor.
        home: Scaffold(body: child),
      ),
    );

Future<void> _tapCta(WidgetTester tester) async {
  // Find the CTA by its real localized label, not by a key a test invented.
  final l10n = await AppL10n.delegate.load(const Locale('ar'));
  final cta = find.widgetWithText(FilledButton, l10n.couponsUseOffer);
  expect(cta, findsOneWidget, reason: 'the real CTA must be present');
  await tester.tap(cta);
  await tester.pumpAndSettle();
  // The paths that launch nothing surface a top banner whose auto-dismiss is a
  // bare 5s Future.delayed, which pumpAndSettle does not drain. Advance past it
  // so teardown does not fail on a pending timer.
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

/// Analytics needs a database in production; the CTA records a click before
/// launching. Overridden so these tests exercise the LAUNCH path, not storage.
class _SpyAnalytics extends CouponAnalyticsClient {
  _SpyAnalytics() : super(loadSettings: () async => throw StateError('unused'));
  final List<String> clicks = <String>[];
  @override
  Future<void> recordCtaClick(String couponId) async => clicks.add(couponId);
  @override
  Future<void> recordImpression(String couponId) async {}
  @override
  Future<void> recordDetailView(String couponId) async {}
  @override
  Future<void> recordCodeCopy(String couponId) async {}
}

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

void main() {
  late _RecordingLauncher launcher;
  late UrlLauncherPlatform previous;

  setUp(() {
    previous = UrlLauncherPlatform.instance;
    launcher = _RecordingLauncher();
    UrlLauncherPlatform.instance = launcher;
  });
  tearDown(() => UrlLauncherPlatform.instance = previous);

  Future<void> pumpSheet(
    WidgetTester tester, {
    required AffiliateClickGateway gateway,
    CouponOffer? offer,
    _SpyAnalytics? analytics,
  }) async {
    await tester.pumpWidget(_app(
      CouponDetailsSheet(offer: offer ?? _offer()),
      overrides: [
        affiliateClickGatewayProvider.overrideWithValue(gateway),
        couponAnalyticsProvider.overrideWithValue(analytics ?? _SpyAnalytics()),
      ],
    ));
    await tester.pumpAndSettle();
  }

  group('what actually reaches the platform launcher', () {
    testWidgets('a valid prepared https URL launches EXACTLY once', (t) async {
      final g = _StubGateway(const ClickResult(
        ClickOutcome.tracked,
        url: 'https://track.example/click/abc',
      ));
      final analytics = _SpyAnalytics();
      await pumpSheet(t, gateway: g, analytics: analytics);
      await _tapCta(t);
      expect(g.opens, 1, reason: 'the CTA must go through the gateway');
      expect(launcher.launched, ['https://track.example/click/abc'],
          reason: 'exactly the prepared URL, exactly once');
      expect(analytics.clicks, ['o1'],
          reason: 'the CTA click is recorded once, before the launch');
    });

    testWidgets('the CTA launches the GATEWAY result, not the raw partner URL',
        (t) async {
      // The regression that source-text guards could not catch.
      final g = _StubGateway(const ClickResult(
        ClickOutcome.tracked,
        url: 'https://track.example/click/xyz',
      ));
      await pumpSheet(t,
          gateway: g, offer: _offer(url: 'https://raw.example/x'));
      await _tapCta(t);
      expect(launcher.launched.single, 'https://track.example/click/xyz');
      expect(launcher.launched.single.contains('raw.example'), isFalse,
          reason: 'the un-prepared partner URL must not be launched');
    });

    testWidgets('a NON-HTTPS url from the gateway is never launched',
        (t) async {
      // Defence in depth is not delegated: whatever the gateway returns is
      // still scheme-checked at the launch site.
      final g = _StubGateway(const ClickResult(ClickOutcome.tracked,
          url: 'http://insecure.example/x'));
      await pumpSheet(t, gateway: g);
      await _tapCta(t);
      expect(launcher.launched, isEmpty);
    });

    testWidgets('a malformed url is never launched', (t) async {
      final g = _StubGateway(
          const ClickResult(ClickOutcome.tracked, url: 'not a url at all'));
      await pumpSheet(t, gateway: g);
      await _tapCta(t);
      expect(launcher.launched, isEmpty);
    });

    testWidgets('preparation failure launches nothing at all', (t) async {
      // `unavailable` with no URL: the user must not be silently told nothing
      // happened AND have a browser opened.
      final g = _StubGateway(const ClickResult(ClickOutcome.unavailable));
      await pumpSheet(t, gateway: g);
      await _tapCta(t);
      expect(g.opens, 1);
      expect(launcher.launched, isEmpty);
    });

    testWidgets('an untracked fallback still opens the merchant URL',
        (t) async {
      // Flag OFF is the shipped state: the gateway returns the plain partner
      // URL and the user still reaches the offer.
      final g = _StubGateway(const ClickResult(
        ClickOutcome.untracked,
        url: 'https://merchant.example/deal',
      ));
      await pumpSheet(t, gateway: g);
      await _tapCta(t);
      expect(launcher.launched, ['https://merchant.example/deal']);
    });
  });

  group('the real gateway, not a stub, decides on flag and consent', () {
    // Uses the PRODUCTION AffiliateClickGateway with injected seams, so the
    // fail-closed logic under test is the shipped one.
    testWidgets('flag OFF makes NO preparation call and opens the plain URL',
        (t) async {
      final calls = <String>[];
      // A real (in-memory) database: the disabled path returns before touching
      // it, and the assertion that matters is that NO preparation call is made.
      //
      // runAsync is required, not stylistic: opening the database awaits real
      // I/O, and a bare `await` inside testWidgets runs on the FAKE clock, which
      // never advances here — the test hangs forever rather than failing.
      final db = (await t.runAsync(() => AppDatabase.open(
            executor: NativeDatabase.memory(),
            keyStore: _MemoryKeyStore(),
          )))!;
      addTearDown(() => t.runAsync(db.close));
      final gateway = AffiliateClickGateway(
        database: db,
        trackingEnabled: () => false,
        prepareClick: (body) async {
          calls.add('prepare');
          return {'url': 'https://track.example/should-not-be-used'};
        },
      );
      await pumpSheet(t, gateway: gateway);
      await _tapCta(t);
      expect(calls, isEmpty, reason: 'a disabled build must make no request');
      expect(launcher.launched, ['https://merchant.example/deal'],
          reason: 'behaviour identical to opening the partner URL directly');
    });

    testWidgets('flag ON DOES prepare, and launches the tracked URL',
        (t) async {
      // Non-vacuity for the test above: it asserts a call is NOT made, which a
      // gateway hard-wired to skip preparation would also satisfy. This proves
      // the same seam is reachable and that the tracked URL is what launches.
      final calls = <Map<String, Object?>>[];
      final db = (await t.runAsync(() => AppDatabase.open(
            executor: NativeDatabase.memory(),
            keyStore: _MemoryKeyStore(),
          )))!;
      addTearDown(() => t.runAsync(db.close));
      final gateway = AffiliateClickGateway(
        database: db,
        trackingEnabled: () => true,
        prepareClick: (body) async {
          calls.add(body);
          return {
            'tracked': true,
            'url': 'https://track.example/click/real',
            'click_id': 'click-1',
            'claim_token': 'token-1',
          };
        },
      );
      await pumpSheet(t, gateway: gateway);
      await _tapCta(t);
      expect(calls.length, 1, reason: 'an enabled build prepares exactly once');
      expect(calls.single['coupon_id'], 'o1');
      expect(launcher.launched, ['https://track.example/click/real']);
    });
  });

  _consentGateTests();
}

/// The consent gate, exercised as a real provider rather than as source text.
///
/// The property that matters is FAIL-CLOSED: while settings are still loading
/// the consent answer is unknown, and unknown must not read as "allowed" — a
/// click is an outbound call tying this user to a merchant visit. A source-text
/// guard could only check that the words `if (settings == null) return false;`
/// appeared somewhere in the file.
void _consentGateTests() {
  group('affiliateTrackingEnabledProvider decides egress', () {
    late AppDatabase db;

    setUp(() async {
      db = await AppDatabase.open(
        executor: NativeDatabase.memory(),
        keyStore: _MemoryKeyStore(),
      );
      // The flag short-circuits before consent is read, so the consent
      // assertions below are only meaningful with the flag ON.
      await RemoteFeatureFlagsDao(db).replaceAll([
        RemoteFeatureFlag(
          key: 'enable_affiliate_links',
          valueType: 'boolean',
          value: 'true',
          rolloutPercent: 100,
          targetCountries: const [],
          isActive: true,
          syncedAt: DateTime.now().toUtc(),
        ),
      ]);
      await initFeatureFlagService(db,
          installIdOverride: 'affiliate-test', applyRemoteOverrides: false);
    });

    tearDown(() async {
      await db.close();
    });

    UserSettingsEntity settingsWith(ConsentState cloud) => UserSettingsEntity(
          id: 'settings',
          country: 'SA',
          currency: 'SAR',
          language: 'ar',
          theme: 'dark',
          inputMethod: 'manual',
          notificationsJson: '{}',
          privacyModeEnabled: false,
          cloudConsentState: cloud,
        );

    /// Reads the provider with settings resolved SYNCHRONOUSLY. Returning a
    /// `Future.value` here would leave the first read in AsyncLoading and every
    /// case would answer false — including the ones that must answer true.
    bool trackingWithConsent(ConsentState cloud) {
      final container = ProviderContainer(overrides: [
        userSettingsProvider.overrideWith((ref) => settingsWith(cloud)),
      ]);
      addTearDown(container.dispose);
      return container.read(affiliateTrackingEnabledProvider);
    }

    /// Settings not yet loaded: the consent answer is unknown.
    bool trackingWhileLoading() {
      final container = ProviderContainer(overrides: [
        userSettingsProvider
            .overrideWith((ref) => Completer<UserSettingsEntity>().future),
      ]);
      addTearDown(container.dispose);
      return container.read(affiliateTrackingEnabledProvider);
    }

    test('consent ACCEPTED with the flag on DOES permit tracking', () {
      // Non-vacuity FIRST: without a case that answers true, the three
      // fail-closed assertions below would also pass for a provider hard-wired
      // to false — which is exactly how the first draft of this test passed
      // while asserting nothing.
      expect(trackingWithConsent(ConsentState.accepted), isTrue);
    });

    test('the FLAG alone can veto, even with consent accepted', () async {
      // The other cases all run with the flag seeded ON, so none of them would
      // notice if the flag check were dropped and consent alone decided. This
      // reseeds the flag OFF with consent still accepted.
      await RemoteFeatureFlagsDao(db).replaceAll([
        RemoteFeatureFlag(
          key: 'enable_affiliate_links',
          valueType: 'boolean',
          value: 'false',
          rolloutPercent: 100,
          targetCountries: const [],
          isActive: true,
          syncedAt: DateTime.now().toUtc(),
        ),
      ]);
      await initFeatureFlagService(db,
          installIdOverride: 'affiliate-test', applyRemoteOverrides: false);
      expect(trackingWithConsent(ConsentState.accepted), isFalse);
    });

    test('consent still LOADING does not permit tracking', () {
      expect(trackingWhileLoading(), isFalse);
    });

    test('consent DECLINED does not permit tracking', () {
      expect(trackingWithConsent(ConsentState.declined), isFalse);
    });

    test('consent UNSET does not permit tracking', () {
      expect(trackingWithConsent(ConsentState.unset), isFalse);
    });
  });
}
