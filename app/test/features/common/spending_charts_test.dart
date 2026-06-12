import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/domain/entities/category_entity.dart';
import 'package:money_companion/features/common/category_catalog.dart';
import 'package:money_companion/features/common/charts/spending_charts.dart';

void main() {
  testWidgets('spending charts render in RTL without throwing', (tester) async {
    final category = CategoryView(
      const CategoryEntity(
        id: 'food',
        key: 'food',
        nameAr: 'مطاعم',
        icon: 'utensils',
        color: '#00C853',
        isIncome: false,
        sort: 1,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            body: ListView(
              children: [
                CategoryDonutChart(
                  slices: [
                    SpendingChartSlice(
                      category: category,
                      total: 120,
                      percent: 1,
                    ),
                  ],
                ),
                const DailySpendBarChart(values: [10, 20, 5]),
                const CompactSparkline(values: [1, 4, 2, 8]),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.pump();

    expect(find.byType(CategoryDonutChart), findsOneWidget);
    expect(find.byType(DailySpendBarChart), findsOneWidget);
    expect(find.byType(CompactSparkline), findsOneWidget);
  });
}
