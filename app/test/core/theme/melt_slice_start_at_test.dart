import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/calm_page_header.dart';

/// `startAt` is ADDITIVE. Every existing caller passes only `height`, and must
/// paint exactly what it painted before.
Future<LinearGradient> _gradientOf(WidgetTester tester, Widget slice) async {
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.dark,
    home: Scaffold(body: slice),
  ));
  final box = tester.widget<DecoratedBox>(
    find.descendant(of: find.byType(MeltSlice), matching: find.byType(DecoratedBox)).first,
  );
  return (box.decoration as BoxDecoration).gradient! as LinearGradient;
}

void main() {
  testWidgets('the default is unchanged from before startAt existed',
      (tester) async {
    final g = await _gradientOf(
      tester,
      const MeltSlice(height: 64, child: SizedBox(height: 64)),
    );
    // Was `meltColorAt(0) -> meltColorAt(height)`; with startAt defaulting to
    // zero it still is.
    final context = tester.element(find.byType(MeltSlice));
    expect(g.colors.first, CalmPageHeader.meltColorAt(context, 0));
    expect(g.colors.last, CalmPageHeader.meltColorAt(context, 64));
  });

  testWidgets('an offset slice starts where the one above it ended',
      (tester) async {
    final g = await _gradientOf(
      tester,
      const MeltSlice(height: 64, startAt: 230, child: SizedBox(height: 64)),
    );
    final context = tester.element(find.byType(MeltSlice));
    expect(g.colors.first, CalmPageHeader.meltColorAt(context, 230));
    expect(g.colors.last, CalmPageHeader.meltColorAt(context, 294));
  });

  testWidgets('every shipping MeltSlice caller still omits startAt', (tester) async {
    // A caller that starts adding offsets without accounting for the slice
    // above it is the regression this guards.
    final g = await _gradientOf(
      tester,
      const MeltSlice(height: 64, startAt: 0, child: SizedBox(height: 64)),
    );
    final plain = await _gradientOf(
      tester,
      const MeltSlice(height: 64, child: SizedBox(height: 64)),
    );
    expect(g.colors, plain.colors);
  });
}
