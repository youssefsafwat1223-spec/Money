import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/liquid_bar.dart';

void main() {
  Widget harness(
    Widget child, {
    TextDirection direction = TextDirection.rtl,
    bool reduceMotion = false,
  }) {
    Widget body = Directionality(
      textDirection: direction,
      child: Center(child: SizedBox(width: 240, child: child)),
    );
    if (reduceMotion) {
      final inner = body;
      body = Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: inner,
        ),
      );
    }
    return MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(body: body),
    );
  }

  double? fillFactor(WidgetTester tester) {
    final boxes = tester
        .widgetList<FractionallySizedBox>(find.byType(FractionallySizedBox));
    for (final b in boxes) {
      if (b.widthFactor != null) return b.widthFactor;
    }
    return null;
  }

  testWidgets('renders the fill at the given value after animating',
      (tester) async {
    await tester.pumpWidget(harness(const LiquidBar(value: 0.5)));
    await tester.pumpAndSettle();
    expect(fillFactor(tester), moreOrLessEquals(0.5));
  });

  testWidgets('null value renders the no-data track with no fill',
      (tester) async {
    await tester.pumpWidget(harness(const LiquidBar(value: null)));
    await tester.pumpAndSettle();
    expect(fillFactor(tester), isNull);
  });

  testWidgets('out-of-range values are clamped', (tester) async {
    await tester.pumpWidget(harness(const LiquidBar(value: 1.8)));
    await tester.pumpAndSettle();
    expect(fillFactor(tester), moreOrLessEquals(1.0));
  });

  testWidgets('reduce-motion renders the target immediately (no tween)',
      (tester) async {
    await tester
        .pumpWidget(harness(const LiquidBar(value: 0.62), reduceMotion: true));
    // First frame, no settle: already at target.
    expect(fillFactor(tester), moreOrLessEquals(0.62));
    expect(find.byType(TweenAnimationBuilder<double>), findsNothing);
  });

  testWidgets('fill is start-aligned so RTL mirrors automatically',
      (tester) async {
    for (final direction in [TextDirection.rtl, TextDirection.ltr]) {
      await tester.pumpWidget(
          harness(const LiquidBar(value: 0.4), direction: direction));
      await tester.pumpAndSettle();
      final align = tester.widget<Align>(find
          .ancestor(
            of: find.byType(FractionallySizedBox),
            matching: find.byType(Align),
          )
          .first);
      expect(align.alignment, AlignmentDirectional.centerStart);
    }
  });
}
