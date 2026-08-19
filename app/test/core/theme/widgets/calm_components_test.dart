import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/calm_chip.dart';
import 'package:money_companion/core/theme/widgets/calm_page_header.dart';
import 'package:money_companion/core/theme/widgets/glass_selector.dart';
import 'package:money_companion/core/utils/app_lucide_icons.dart';

Widget _host(Widget child, {ThemeData? theme}) => MaterialApp(
      theme: theme ?? AppTheme.light,
      home: Scaffold(body: child),
    );

void main() {
  testWidgets(
      'CalmPageHeader renders title, subtitle, amount + currency, '
      'and the metric strip', (tester) async {
    await tester.pumpWidget(_host(const CalmPageHeader(
      title: 'العمليات',
      subtitle: 'إجمالي مصروفات الفترة',
      amount: '8,430',
      currency: 'ريال',
      topInset: 0,
      metrics: [
        CalmMetric(label: 'عملية للفترة', value: '142'),
        CalmMetric(label: 'قيد المراجعة', value: '3'),
      ],
    )));
    expect(find.text('العمليات'), findsOneWidget);
    expect(find.text('إجمالي مصروفات الفترة'), findsOneWidget);
    expect(find.text('8,430'), findsOneWidget);
    expect(find.text('ريال'), findsOneWidget);
    expect(find.text('142'), findsOneWidget);
    expect(find.text('عملية للفترة'), findsOneWidget);
  });

  testWidgets('CalmPageHeader works with title only (no amount/metrics)',
      (tester) async {
    await tester.pumpWidget(
        _host(const CalmPageHeader(title: 'الإعدادات', topInset: 0)));
    expect(find.text('الإعدادات'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('CalmChip toggles and reports taps', (tester) async {
    var tapped = false;
    await tester.pumpWidget(_host(Row(children: [
      CalmChip(label: 'الكل', selected: true, onTap: () {}),
      CalmChip(label: 'مصروفات', selected: false, onTap: () => tapped = true),
    ])));
    expect(find.text('الكل'), findsOneWidget);
    await tester.tap(find.text('مصروفات'));
    expect(tapped, isTrue);
  });

  testWidgets('GlassSelector shows its label and is tappable', (tester) async {
    var tapped = false;
    await tester.pumpWidget(_host(GlassSelector(
      icon: AppLucideIcons.calendarDays,
      label: 'هذا الشهر',
      onTap: () => tapped = true,
    )));
    expect(find.text('هذا الشهر'), findsOneWidget);
    await tester.tap(find.byType(GlassSelector));
    expect(tapped, isTrue);
  });

  testWidgets('shared components render on the dark theme', (tester) async {
    await tester.pumpWidget(_host(
      const CalmPageHeader(
          title: 'التقارير', amount: '1,200', currency: 'ريال', topInset: 0),
      theme: AppTheme.dark,
    ));
    expect(find.text('التقارير'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
