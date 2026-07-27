import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/attention_card.dart';
import 'package:money_companion/core/theme/widgets/insight_card.dart';
import 'package:money_companion/core/theme/widgets/ledger_row.dart';
import 'package:money_companion/core/theme/widgets/pulse_row.dart';

Widget _host(Widget child, {ThemeData? theme}) => MaterialApp(
      theme: theme ?? AppTheme.light,
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('PulseRow renders each metric label + value', (tester) async {
    await tester.pumpWidget(_host(const PulseRow(metrics: [
      PulseMetric(label: 'دخل اليوم', value: '+12,500'),
      PulseMetric(label: 'مصروف اليوم', value: '−3,240'),
      PulseMetric(label: 'الصافي', value: '+9,260'),
    ])));
    expect(find.text('دخل اليوم'), findsOneWidget);
    expect(find.text('+12,500'), findsOneWidget);
    expect(find.text('الصافي'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AttentionCard shows title + subtitle and is tappable',
      (tester) async {
    var tapped = false;
    await tester.pumpWidget(_host(AttentionCard(
      icon: Icons.warning_amber_rounded,
      title: '٣ عمليات في انتظار مراجعتك',
      subtitle: 'راجعها عشان أرصدتك تفضل مظبوطة',
      onTap: () => tapped = true,
    )));
    expect(find.text('٣ عمليات في انتظار مراجعتك'), findsOneWidget);
    expect(find.text('راجعها عشان أرصدتك تفضل مظبوطة'), findsOneWidget);
    await tester.tap(find.byType(AttentionCard));
    expect(tapped, isTrue);
  });

  testWidgets('InsightCard renders eyebrow, message and CTA', (tester) async {
    await tester.pumpWidget(_host(const InsightCard(
      label: 'مساعد مالي',
      message: 'مصروفك على المطاعم أقل بـ18% عن الشهر اللي فات.',
      ctaText: 'التفاصيل',
    )));
    expect(find.text('مساعد مالي'), findsOneWidget);
    expect(find.textContaining('المطاعم'), findsOneWidget);
    expect(find.text('التفاصيل'), findsOneWidget);
  });

  testWidgets('LedgerRow shows amount + pending/AI badges only when flagged',
      (tester) async {
    await tester.pumpWidget(_host(const Column(children: [
      LedgerRow(
        icon: Icons.shopping_bag_outlined,
        iconTint: Colors.red,
        title: 'نون · تسوّق',
        subtitle: '2:14 م · تسوق',
        amount: '−320.00',
      ),
      LedgerRow(
        icon: Icons.coffee_outlined,
        iconTint: Colors.orange,
        title: 'ستاربكس',
        subtitle: '8:10 ص · كافيهات',
        amount: '−27.50',
        isPending: true,
        isAi: true,
      ),
    ])));
    expect(find.text('نون · تسوّق'), findsOneWidget);
    expect(find.text('−320.00'), findsOneWidget);
    // Badges appear once — only on the flagged row.
    expect(find.text('مراجعة'), findsOneWidget);
    expect(find.text('ذكاء'), findsOneWidget);
  });

  testWidgets('archetypes render on the dark theme too', (tester) async {
    await tester.pumpWidget(_host(
      const PulseRow(metrics: [
        PulseMetric(label: 'الصافي', value: '+9,260'),
      ]),
      theme: AppTheme.dark,
    ));
    expect(find.text('الصافي'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
