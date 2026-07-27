import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/account_card.dart';
import 'package:money_companion/core/theme/widgets/balance_statement.dart';
import 'package:money_companion/core/theme/widgets/budget_ring_rail.dart';
import 'package:money_companion/core/theme/widgets/donut_chart.dart';
import 'package:money_companion/core/theme/widgets/merchant_bar.dart';
import 'package:money_companion/core/theme/widgets/score_gauge.dart';
import 'package:money_companion/core/theme/widgets/segmented_control.dart';
import 'package:money_companion/core/theme/widgets/sheet_field.dart';

Widget _host(Widget child) => MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(body: Padding(padding: const EdgeInsets.all(16), child: child)),
    );

void main() {
  testWidgets('BalanceStatement shows label, amount, currency and trend',
      (tester) async {
    await tester.pumpWidget(_host(const BalanceStatement(
      label: 'الرصيد الكلي',
      amount: '48,250.00',
      currency: 'ريال',
      trendText: '2.4% هذا الشهر',
      trendIcon: Icons.trending_up_rounded,
    )));
    expect(find.text('الرصيد الكلي'), findsOneWidget);
    expect(find.text('48,250.00'), findsOneWidget);
    expect(find.text('ريال'), findsOneWidget);
    expect(find.text('2.4% هذا الشهر'), findsOneWidget);
  });

  testWidgets('ScoreGauge renders the score and no-data dash', (tester) async {
    await tester.pumpWidget(_host(const Column(children: [
      ScoreGauge(score: 78, caption: 'من 100'),
      ScoreGauge(score: null),
    ])));
    expect(find.text('78'), findsOneWidget);
    expect(find.text('—'), findsOneWidget);
  });

  testWidgets('DonutChart renders with segments and a no-data fallback',
      (tester) async {
    await tester.pumpWidget(_host(const DonutChart(segments: [
      DonutSegment(value: 34, color: Colors.blue),
      DonutSegment(value: 22, color: Colors.indigo),
    ], animate: false)));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(_host(const DonutChart(segments: [], animate: false)));
    expect(tester.takeException(), isNull);
  });

  testWidgets('MerchantBar / SegmentedControl / SheetField render',
      (tester) async {
    await tester.pumpWidget(_host(Column(children: [
      const MerchantBar(name: 'نون', amount: '1,240', fraction: 1.0, meta: '8 عمليات'),
      SegmentedControl<int>(
        value: 0,
        onChanged: (_) {},
        options: const [
          SegmentOption(value: 0, label: 'مصروف'),
          SegmentOption(value: 1, label: 'دخل'),
          SegmentOption(value: 2, label: 'تحويل'),
        ],
      ),
      const SheetField(icon: Icons.wallet_outlined, label: 'الحساب', value: 'بنك مصر · ريال'),
    ])));
    expect(find.text('نون'), findsOneWidget);
    expect(find.text('مصروف'), findsOneWidget);
    expect(find.text('بنك مصر · ريال'), findsOneWidget);
  });

  // No-overflow guards on the composite row/rail widgets at a narrow width.
  for (final size in [const Size(390, 844), const Size(360, 720)]) {
    testWidgets('no overflow at ${size.width.toInt()}px', (tester) async {
      final view = tester.view;
      view.physicalSize = size * view.devicePixelRatio;
      addTearDown(view.resetPhysicalSize);
      addTearDown(view.resetDevicePixelRatio);
      await tester.pumpWidget(_host(Column(children: [
        const BalanceStatement(
            label: 'الرصيد الكلي', amount: '48,250.00', currency: 'ريال'),
        const SizedBox(height: 12),
        const BudgetRingRail(rings: [
          BudgetRing(value: 0.7, name: 'مطاعم', sub: '700 / 1000'),
          BudgetRing(value: 0.88, name: 'تسوّق', sub: '1,760 / 2,000'),
          BudgetRing(value: 0.3, name: 'مواصلات', sub: '150 / 500'),
        ]),
        const SizedBox(height: 12),
        AccountCard(
          icon: Icons.account_balance_rounded,
          tint: Colors.blue,
          name: 'بنك مصر',
          subtitle: 'بنك · ريال (SAR)',
          balance: '42,180',
          balanceCurrency: 'ريال',
          isDefault: true,
          onTap: () {},
        ),
      ])));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('archetypes render on dark theme', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: const Scaffold(
        body: BudgetRingRail(rings: [
          BudgetRing(value: 0.5, name: 'مطاعم', sub: '500 / 1000'),
        ]),
      ),
    ));
    expect(tester.takeException(), isNull);
    expect(find.text('مطاعم'), findsOneWidget);
  });
}
