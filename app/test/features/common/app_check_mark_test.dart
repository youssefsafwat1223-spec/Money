import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_colors.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/common/app_check_mark.dart';
import 'package:money_companion/core/utils/app_lucide_icons.dart';

void main() {
  Widget harness(Widget child) => MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(body: Center(child: child)),
      );

  testWidgets('selected fills with ink and shows the check', (tester) async {
    await tester.pumpWidget(harness(const AppCheckMark(selected: true)));
    await tester.pumpAndSettle();
    expect(find.byIcon(AppLucideIcons.check), findsOneWidget);
    final box =
        tester.widget<AnimatedContainer>(find.byType(AnimatedContainer));
    final decoration = box.decoration! as BoxDecoration;
    expect(decoration.color, AppColors.light.ink);
    expect(decoration.border, isNull);
  });

  testWidgets('unselected shows a quiet border and no check', (tester) async {
    await tester.pumpWidget(harness(const AppCheckMark(selected: false)));
    await tester.pumpAndSettle();
    expect(find.byIcon(AppLucideIcons.check), findsNothing);
    final box =
        tester.widget<AnimatedContainer>(find.byType(AnimatedContainer));
    final decoration = box.decoration! as BoxDecoration;
    expect(decoration.color, Colors.transparent);
    expect(decoration.border, isNotNull);
  });

  testWidgets('exposes the checked state to semantics', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(harness(const AppCheckMark(selected: true)));
    await tester.pumpAndSettle();
    final node = tester.getSemantics(find.byType(AppCheckMark));
    expect(node.hasFlag(SemanticsFlag.isChecked), isTrue);
    handle.dispose();
  });
}
