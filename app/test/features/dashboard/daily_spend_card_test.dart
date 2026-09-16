import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/domain/entities/report_models.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/common/category_catalog.dart';
import 'package:money_companion/features/dashboard/widgets/daily_spend_card.dart';
import 'package:money_companion/l10n/app_localizations.dart';

Money sar(int minor) => Money(minor, 'SAR');

List<DailySpend> sevenDays(List<int> minors) {
  final today = DateTime(2026, 8, 31);
  return [
    for (var i = 0; i < minors.length; i++)
      DailySpend(
        day: today.subtract(Duration(days: minors.length - 1 - i)),
        total: sar(minors[i]),
      ),
  ];
}

Future<void> pumpCard(
  WidgetTester tester, {
  required Money todaySpend,
  required List<DailySpend> days,
  Money? availableToday,
  double? todayVsYesterday,
  bool privacyMode = false,
  bool todayIsTruncated = false,
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppL10n.localizationsDelegates,
    supportedLocales: AppL10n.supportedLocales,
    theme: AppTheme.dark,
    locale: const Locale('ar'),
    home: Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        body: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: DailySpendCard(
              todaySpend: todaySpend,
              lastSevenDays: days,
              averageSevenDays: sar(24304),
              availableToday: availableToday,
              todayVsYesterday: todayVsYesterday,
              todayTransactions: const [],
              todayIsTruncated: todayIsTruncated,
              catalog: CategoryCatalog(const []),
              currencyLabel: 'ريال',
              privacyMode: privacyMode,
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  final days = sevenDays([38000, 56000, 22000, 70000, 45000, 62000, 23850]);

  testWidgets('renders the day figure and its label', (tester) async {
    await pumpCard(tester, todaySpend: sar(23850), days: days);

    expect(find.text('صرفت اليوم'), findsOneWidget);
    expect(find.text('238.50'), findsOneWidget);
    expect(find.text('ريال'), findsOneWidget);
  });

  testWidgets('no monthly budget shows «—» and prompts for one — never a zero',
      (tester) async {
    await pumpCard(
        tester, todaySpend: sar(23850), days: days, availableToday: null);

    expect(find.text('—'), findsOneWidget);
    expect(find.text('حدّد ميزانية شهرية'), findsOneWidget);
    expect(find.text('متاح لليوم'), findsNothing);
  });

  testWidgets('with a budget it shows the allowance under «متاح لليوم»',
      (tester) async {
    await pumpCard(
      tester,
      todaySpend: sar(23850),
      days: days,
      availableToday: sar(14902),
    );

    expect(find.text('متاح لليوم'), findsOneWidget);
    expect(find.text('149.02'), findsOneWidget);
    expect(find.text('حدّد ميزانية شهرية'), findsNothing);
  });

  testWidgets('the vs-yesterday chip is omitted when the ratio is undefined',
      (tester) async {
    await pumpCard(
        tester, todaySpend: sar(23850), days: days, todayVsYesterday: null);

    expect(find.textContaining('عن أمس'), findsNothing);
  });

  testWidgets('a drop against yesterday reads as a signed percentage',
      (tester) async {
    await pumpCard(
      tester,
      todaySpend: sar(23850),
      days: days,
      todayVsYesterday: -0.2385,
    );

    expect(find.text('−24% عن أمس'), findsOneWidget);
  });

  testWidgets('an extreme spike is capped so it cannot break the row',
      (tester) async {
    await pumpCard(
      tester,
      todaySpend: sar(23850),
      days: days,
      todayVsYesterday: 45.0, // +4500%
    );

    expect(find.text('+999% عن أمس'), findsOneWidget);
  });

  testWidgets('privacy mode masks every figure on the card', (tester) async {
    await pumpCard(
      tester,
      todaySpend: sar(23850),
      days: days,
      availableToday: sar(14902),
      privacyMode: true,
    );

    expect(find.text('238.50'), findsNothing);
    expect(find.text('149.02'), findsNothing);
    expect(find.text('••••'), findsWidgets);
  });

  testWidgets('a truncated read renders the count as «+N», never as exact',
      (tester) async {
    await pumpCard(
      tester,
      todaySpend: sar(23850),
      days: days,
      todayIsTruncated: true,
    );

    expect(find.text('عمليات اليوم'), findsOneWidget);
    expect(find.text('+0'), findsOneWidget);
  });

  testWidgets('today is the only highlighted bar — the days are one series',
      (tester) async {
    await pumpCard(tester, todaySpend: sar(23850), days: days);

    // Six weekday initials + «اليوم» for the last slot.
    expect(find.text('اليوم'), findsOneWidget);
  });

  testWidgets('survives a 320px width without overflowing', (tester) async {
    await pumpCard(
      tester,
      todaySpend: sar(1234567),
      days: days,
      availableToday: sar(14902),
      size: const Size(320, 800),
    );

    expect(tester.takeException(), isNull);
  });

  testWidgets('survives a large accessibility text scale', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppL10n.localizationsDelegates,
      supportedLocales: AppL10n.supportedLocales,
      locale: const Locale('ar'),
      theme: AppTheme.light,
      home: MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
        child: Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            body: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: DailySpendCard(
                  todaySpend: sar(23850),
                  lastSevenDays: days,
                  averageSevenDays: sar(24304),
                  availableToday: sar(14902),
                  todayVsYesterday: -0.24,
                  todayTransactions: const [],
                  todayIsTruncated: false,
                  catalog: CategoryCatalog(const []),
                  currencyLabel: 'ريال',
                  privacyMode: false,
                ),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
