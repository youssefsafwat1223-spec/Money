import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/catalog/announcement_service.dart';
import 'package:money_companion/data/catalog/catalog_daos.dart';
import 'package:money_companion/data/catalog/growth_campaign_service.dart';
import 'package:money_companion/features/common/widgets/announcement_banner.dart';
import 'package:money_companion/l10n/app_localizations.dart';

final _now = DateTime.utc(2026, 10, 29);
RemoteAnnouncement _announcement() => RemoteAnnouncement(
  id: 'announcement', titleAr: 'تنبيه جديد', titleEn: 'A new notice',
  bodyAr: 'النص الكامل للتنبيه', bodyEn: 'The complete notice body',
  severity: 'warning', minAppVersion: null, maxAppVersion: null,
  actionLabelAr: 'افتح', actionLabelEn: 'Open', actionUrl: '/destination',
  validFrom: _now, validUntil: null, isDismissible: true, priority: 1,
  isDismissed: false, dismissedAt: null, syncedAt: _now,
);
RemoteGrowthCampaign _campaign() => RemoteGrowthCampaign(
  id: 'campaign', titleAr: 'حملة جديدة', titleEn: 'A new campaign',
  bodyAr: 'النص الكامل للحملة', bodyEn: 'The complete campaign body',
  type: 'dashboard_banner', targetSegment: 'all',
  actionLabelAr: 'عرض', actionLabelEn: 'View', actionRoute: '/destination',
  actionUrl: null, validFrom: _now, validUntil: null, maxImpressions: null,
  cooldownHours: 0, isDismissible: true, oncePerUser: false, priority: 1,
  isActive: true, syncedAt: _now,
);

class _Announcements implements AnnouncementService {
  bool dismissed = false;
  @override
  Future<void> dismiss(String id) async { expect(id, 'announcement'); dismissed = true; }
  @override
  Future<List<RemoteAnnouncement>> getActiveAnnouncements() async =>
      dismissed ? [] : [_announcement()];
  @override
  Future<bool> hasForceUpdate() async => false;
}
class _Campaigns implements GrowthCampaignService {
  bool dismissed = false;
  int impressions = 0;
  @override
  Future<void> dismiss(String id) async { expect(id, 'campaign'); dismissed = true; }
  @override
  Future<void> recordImpression(String id) async { expect(id, 'campaign'); impressions++; }
  @override
  Future<List<RemoteGrowthCampaign>> visibleDashboardBanners() async =>
      dismissed ? [] : [_campaign()];
}

Future<GoRouter> _open(WidgetTester tester, String language, bool dark,
    _Announcements announcements, _Campaigns campaigns, bool campaign) async {
  tester.view.physicalSize = const Size(320, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = GoRouter(routes: [
    GoRoute(path: '/', builder: (_, __) => const Scaffold(
      body: SafeArea(child: AnnouncementBanner()))),
    GoRoute(path: '/destination', builder: (_, __) => const Scaffold(
      body: Text('Reached destination'))),
  ]);
  addTearDown(router.dispose);
  await tester.pumpWidget(ProviderScope(overrides: [
    announcementServiceProvider.overrideWithValue(announcements),
    growthCampaignServiceProvider.overrideWithValue(campaigns),
    activeAnnouncementsProvider.overrideWith((ref) async => campaign
        ? [] : ref.read(announcementServiceProvider).getActiveAnnouncements()),
    activeDashboardCampaignsProvider.overrideWith((ref) async => campaign
        ? ref.read(growthCampaignServiceProvider).visibleDashboardBanners() : []),
  ], child: MaterialApp.router(
    theme: dark ? AppTheme.dark : AppTheme.light,
    locale: Locale(language), supportedLocales: AppL10n.supportedLocales,
    localizationsDelegates: AppL10n.localizationsDelegates,
    routerConfig: router,
  )));
  await tester.pumpAndSettle();
  return router;
}

void main() {
  for (final language in ['ar', 'en']) {
    for (final dark in [false, true]) {
      testWidgets('notice content routing and dismiss survive $language dark=$dark',
          (tester) async {
        final announcements = _Announcements();
        final router = await _open(tester, language, dark,
            announcements, _Campaigns(), false);
        final title = language == 'ar' ? 'تنبيه جديد' : 'A new notice';
        final body = language == 'ar' ? 'النص الكامل للتنبيه' : 'The complete notice body';
        expect(find.text(body), findsOneWidget);
        expect(tester.getSize(find.byType(AnnouncementBanner)).height,
            lessThan(220), reason: 'the notice must remain a compact card at320px');
        await tester.tap(find.text(title));
        await tester.pumpAndSettle();
        expect(find.text('Reached destination'), findsOneWidget);
        router.pop();
        await tester.pumpAndSettle();
        final l10n = AppL10n.of(tester.element(find.byType(AnnouncementBanner)));
        await tester.tap(find.byTooltip(l10n.commonHide));
        await tester.pumpAndSettle();
        expect(announcements.dismissed, isTrue);
        expect(find.text(title), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
    testWidgets('campaign records one impression and retains CTA in $language',
        (tester) async {
      final campaigns = _Campaigns();
      final router = await _open(tester, language, false,
          _Announcements(), campaigns, true);
      expect(campaigns.impressions, 1);
      expect(find.text(language == 'ar' ? 'النص الكامل للحملة'
          : 'The complete campaign body'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton,
          language == 'ar' ? 'عرض' : 'View'));
      await tester.pumpAndSettle();
      expect(find.text('Reached destination'), findsOneWidget);
      router.pop();
      await tester.pumpAndSettle();
      expect(campaigns.impressions, 1);
      final l10n = AppL10n.of(tester.element(find.byType(AnnouncementBanner)));
      await tester.tap(find.byTooltip(l10n.commonHide));
      await tester.pumpAndSettle();
      expect(campaigns.dismissed, isTrue);
      expect(find.text(language == 'ar' ? 'حملة جديدة' : 'A new campaign'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
