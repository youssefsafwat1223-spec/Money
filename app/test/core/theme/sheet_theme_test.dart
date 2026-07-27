import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_colors.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/navy_sheet_theme.dart';

void main() {
  testWidgets('sheet wrapper follows the ambient theme — light app → light sheet',
      (tester) async {
    const sheetKey = ValueKey('sheet-content');

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: navySheetTheme(
            Builder(
              builder: (context) => ColoredBox(
                key: sheetKey,
                color: context.colors.surface,
                child: Text(
                  'الحسابات والمحافظ',
                  style: TextStyle(color: context.colors.textPrimary),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final context = tester.element(find.byKey(sheetKey));
    expect(Theme.of(context).brightness, Brightness.light);
    expect(context.colors, AppColors.light);
    expect(
      tester.widget<Text>(find.text('الحسابات والمحافظ')).style?.color,
      AppColors.light.textPrimary,
    );
  });

  testWidgets('sheet wrapper follows the ambient theme — dark app → dark sheet',
      (tester) async {
    const sheetKey = ValueKey('sheet-content');

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: navySheetTheme(
            Builder(
              builder: (context) => ColoredBox(
                key: sheetKey,
                color: context.colors.surface,
              ),
            ),
          ),
        ),
      ),
    );

    final context = tester.element(find.byKey(sheetKey));
    expect(Theme.of(context).brightness, Brightness.dark);
    expect(context.colors, AppColors.dark);
  });

  test('bottom sheet surface matches the mockups (charcoal dark / white light)',
      () {
    final light = AppTheme.light.bottomSheetTheme;
    expect(light.backgroundColor, AppTheme.sheetSurfaceLight);
    expect(light.modalBackgroundColor, AppTheme.sheetSurfaceLight);
    expect(light.dragHandleColor, AppColors.light.textSecondary);
    expect(light.clipBehavior, Clip.antiAlias);

    final dark = AppTheme.dark.bottomSheetTheme;
    expect(dark.backgroundColor, AppTheme.sheetSurfaceDark);
    expect(dark.modalBackgroundColor, AppTheme.sheetSurfaceDark);
    expect(dark.dragHandleColor, AppColors.dark.textSecondary);
  });

  testWidgets('sheet wrapper only applies a Theme, no extra painted surface',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: navySheetTheme(const SizedBox(key: ValueKey('content'))),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('content')), findsOneWidget);
    final ctx = tester.element(find.byKey(const ValueKey('content')));
    expect(Theme.of(ctx).brightness, Brightness.dark);
  });
}
