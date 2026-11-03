import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/utils/currency.dart';
import 'package:money_companion/domain/entities/category_entity.dart';
import 'package:money_companion/domain/entities/report_models.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/ads/ad_placement.dart';
import 'package:money_companion/features/ads/banner_ads_providers.dart';
import 'package:money_companion/features/common/app_card.dart';
import 'package:money_companion/features/common/category_catalog.dart';
import 'package:money_companion/features/dashboard/dashboard_providers.dart';
import 'package:money_companion/features/reports/reports_providers.dart';
import 'package:money_companion/features/reports/reports_screen.dart';
import 'package:money_companion/features/settings/settings_providers.dart';
import 'package:money_companion/l10n/app_localizations.dart';

ReportSection _weekly() => ReportSection(
  total: Money(58487, 'KWD'), prevTotal: Money(100000, 'KWD'),
  refunds: Money.zero('KWD'),
  topCategories: [CategorySlice(
    category: CategoryView(const CategoryEntity(id: 'demo', key: 'demo',
      nameAr: 'Demo category', icon: 'shopping-cart', color: '#16A37F',
      isIncome: false, sort: 1)),
    total: Money(58487, 'KWD'), percent: 1,
  )],
  topMerchants: [MerchantSpend(name: 'DEMO MERCHANT', total: Money(46142, 'KWD'), count: 1)],
  dailySpend: [DailySpend(day: DateTime(2026, 11, 1), total: Money(12345, 'KWD'))],
  anomaly: null,
);

ReportSection _emptyMonthly() => ReportSection(
  total: Money.zero('KWD'), prevTotal: Money.zero('KWD'), refunds: Money.zero('KWD'),
  topCategories: const [], topMerchants: const [], dailySpend: const [], anomaly: null,
);

void main() {
  for (final language in ['ar', 'en']) {
    for (final theme in [AppTheme.light, AppTheme.dark]) {
      for (final privacy in [true, false]) {
        testWidgets('weekly insight $language ${theme.brightness.name} privacy$privacy masks both amounts or preserves exact KWD precision',
            (tester) async {
          tester.view.physicalSize = const Size(375, 812);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.runAsync(() async {
            final fonts = FontLoader('Vazirmatn');
            for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
              fonts.addFont(rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
            }
            await fonts.load();
          });
          final weekly = _weekly();
          await tester.pumpWidget(ProviderScope(overrides: [
            reportsProvider.overrideWith((ref) async => ReportsBundle(
                weekly: weekly, monthly: _emptyMonthly())),
            baseCurrencyProvider.overrideWith((ref) async => 'KWD'),
            userSettingsProvider.overrideWith((ref) => UserSettingsEntity(
              id: 'synthetic', country: 'KW', currency: 'KWD', language: language,
              theme: 'system', inputMethod: 'manual', notificationsJson: '{}',
              privacyModeEnabled: privacy,
            )),
            for (final placement in AdPlacement.values)
              bannerEligibilityProvider(placement).overrideWith((ref) async => false),
          ], child: MaterialApp(theme: theme, locale: Locale(language),
            supportedLocales: AppL10n.supportedLocales,
            localizationsDelegates: AppL10n.localizationsDelegates,
            home: const ReportsScreen(),
          )));
          await tester.pumpAndSettle();
          final context = tester.element(find.byType(ReportsScreen));
          final l10n = AppL10n.of(context);
          final heading = find.text(l10n.rptWeekSummary);
          for (var i = 0; i < 10 && heading.evaluate().isEmpty; i++) {
            await tester.drag(find.byType(NestedScrollView), const Offset(0, -300));
            await tester.pumpAndSettle();
          }
          expect(heading, findsOneWidget);
          await tester.ensureVisible(heading);
          await tester.pumpAndSettle();
          final card = find.ancestor(of: heading, matching: find.byType(AppCard)).first;
          final currency = Currency.label(context, 'KWD');
          final best = l10n.rptBestSavingDay('1/11',
              privacy ? '•••• $currency' : '12.345 $currency');
          final merchant = l10n.rptTopMerchantWeek('DEMO MERCHANT',
              privacy ? '•••• $currency' : '46.142 $currency');
          final rendered = tester.widgetList<Text>(find.descendant(of: card,
              matching: find.byType(Text))).map((t) => t.data).toList();
          expect(rendered, containsAll([best, merchant]),
              reason: 'Both financial insight leaves must honor privacy and canonical scale.');
          expect(find.descendant(of: card,
              matching: find.text(l10n.rptTopCategoryWeek('Demo category'))), findsOneWidget);
          expect(find.descendant(of: card,
              matching: find.text(l10n.rptVsLastWeek('↓', '42'))), findsOneWidget);
          if (privacy) {
            for (final raw in ['12.345', '12.35', '46.142', '46.14']) {
              expect(find.descendant(of: card, matching: find.textContaining(raw)), findsNothing);
            }
            expect(find.descendant(of: card, matching: find.textContaining('••••')), findsNWidgets(2));
          }
          // Presentation must not mutate any exact financial values.
          expect(weekly.bestSavingsDay!.total, Money(12345, 'KWD'));
          expect(weekly.topMerchant!.total, Money(46142, 'KWD'));
          expect(weekly.total, Money(58487, 'KWD'));
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
