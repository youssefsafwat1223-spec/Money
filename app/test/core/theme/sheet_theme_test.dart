import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_colors.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/navy_sheet_theme.dart';

void main() {
  testWidgets('modal sheet wrapper applies navy theme with light text',
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
                color: context.colors.surfaceElevated,
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
    expect(Theme.of(context).brightness, Brightness.dark);
    expect(context.colors, AppTheme.sheetColors);
    expect(
      tester.widget<Text>(find.text('الحسابات والمحافظ')).style?.color,
      AppTheme.sheetColors.textPrimary,
    );
  });

  test('light app theme keeps the complete modal surface navy', () {
    final sheetTheme = AppTheme.light.bottomSheetTheme;

    expect(
      sheetTheme.modalBackgroundColor,
      AppTheme.sheetColors.surfaceElevated,
    );
    expect(sheetTheme.backgroundColor, AppTheme.sheetColors.surfaceElevated);
    expect(sheetTheme.dragHandleColor, AppTheme.sheetColors.textSecondary);
    expect(sheetTheme.clipBehavior, Clip.antiAlias);
  });

  test('sheet wrapper does not add a second painted surface', () {
    final wrapped = navySheetTheme(
      const SizedBox(key: ValueKey('content')),
    );

    expect(wrapped, isA<Theme>());
    expect((wrapped as Theme).child, isA<SizedBox>());
  });
}
