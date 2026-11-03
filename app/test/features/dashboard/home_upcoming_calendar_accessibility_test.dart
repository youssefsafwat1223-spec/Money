import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/domain/entities/bill_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/dashboard/widgets/home_overview_cards.dart';
import 'package:money_companion/l10n/app_localizations.dart';

void main() {
  Future<void> pumpCard(WidgetTester tester, {
    required String language, required ThemeData theme,
    required double width, required double scale,
    List<BillEntity> bills = const [], VoidCallback? onTap,
  }) async {
    tester.view.physicalSize = Size(width, 874);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      final fonts = FontLoader('Vazirmatn');
      for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
        fonts.addFont(rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
      }
      await fonts.load();
    });
    await tester.pumpWidget(ProviderScope(overrides: [
      merchantLogosProvider.overrideWith((ref) async => const {}),
    ], child: MaterialApp(
      theme: theme, locale: Locale(language),
      supportedLocales: AppL10n.supportedLocales,
      localizationsDelegates: AppL10n.localizationsDelegates,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!),
      home: Scaffold(body: SingleChildScrollView(child: Padding(
        padding: const EdgeInsets.all(16),
        child: UpcomingPaymentsCard(bills: bills, privacyMode: false,
          now: DateTime(2026, 10, 31), onTap: onTap ?? () {}),
      ))),
    )));
    await tester.pumpAndSettle();
  }

  for (final language in ['ar', 'en']) {
    for (final theme in [AppTheme.light, AppTheme.dark]) {
      for (final width in [375.0, 402.0]) {
        for (final scale in [1.0, 2.14]) {
          testWidgets('14-day strip $language ${theme.brightness.name} width$width scale$scale retains complete calendar without overflow',
              (tester) async {
            await pumpCard(tester, language: language, theme: theme,
                width: width, scale: scale);
            final strip = find.byType(ListView);
            expect(strip, findsOneWidget);
            final firstDay = find.descendant(of: strip, matching: find.text('31'));
            expect(firstDay, findsOneWidget);
            if (scale == 1) {
              expect(tester.getSize(strip).height, 64);
              final tile = find.ancestor(of: firstDay,
                  matching: find.byWidgetPredicate((w) => w is Container &&
                      w.constraints?.minWidth == 46)).first;
              expect(tester.getSize(tile), const Size(46, 64));
            }
            final errors = <Object>[];
            void collectErrors() {
              Object? error;
              while ((error = tester.takeException()) != null) {
                errors.add(error!);
              }
            }
            collectErrors();
            // Scroll the actual 14-day rail through the month boundary so every
            // lazy date cell is laid out with the real Arabic/Latin app font.
            for (var i = 0; i < 4; i++) {
              await tester.drag(strip, Offset(language == 'ar' ? 250 : -250, 0));
              await tester.pumpAndSettle();
              collectErrors();
            }
            expect(find.descendant(of: strip, matching: find.text('13')), findsOneWidget);
            expect(errors, isEmpty,
                reason: 'Every date cell must fit at the requested font scale.');
          });
        }
      }

      testWidgets('upcoming bill values and card callback retained in $language ${theme.brightness.name}',
          (tester) async {
        var taps = 0;
        final bill = BillEntity(id: 'synthetic-bill', name: 'Demo',
          amountMoney: Money(1234, 'EGP'), currency: 'EGP',
          type: BillType.subscription, frequency: BillFrequency.monthly,
          nextDueDate: DateTime(2026, 11, 2), reminderOn: true,
          isConfirmed: true, createdAt: DateTime(2026, 1, 1));
        await pumpCard(tester, language: language, theme: theme,
            width: 375, scale: 1, bills: [bill], onTap: () => taps++);
        expect(find.text('Demo'), findsOneWidget);
        expect(find.textContaining('12.34'), findsOneWidget);
        await tester.tap(find.text('Demo'));
        expect(taps, 1);
        expect(bill.amountMoney, Money(1234, 'EGP'));
        expect(bill.nextDueDate, DateTime(2026, 11, 2));
        expect(tester.takeException(), isNull);
      });
    }
  }
}
