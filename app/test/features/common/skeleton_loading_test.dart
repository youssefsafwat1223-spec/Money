import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_spacing.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/common/premium_loading.dart';

void main() {
  Widget harness(Widget child, {bool reduceMotion = false}) {
    Widget body = child;
    if (reduceMotion) {
      final inner = body;
      body = Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: inner,
        ),
      );
    }
    return MaterialApp(theme: AppTheme.light, home: Scaffold(body: body));
  }

  testWidgets('SkeletonRow is row-shaped: round avatar tile + bars',
      (tester) async {
    await tester.pumpWidget(harness(
        const Center(child: SizedBox(width: 360, child: SkeletonRow())),
        reduceMotion: true));
    final tile = tester.getSize(find
        .descendant(
            of: find.byType(SkeletonRow), matching: find.byType(SizedBox))
        .first);
    expect(tile.width, AppSpacing.avatar);
    expect(tile.height, AppSpacing.avatar);
    expect(find.byType(FractionallySizedBox), findsNWidgets(2));
  });

  testWidgets('SkeletonList renders the requested rows and optional hero',
      (tester) async {
    await tester
        .pumpWidget(harness(const SkeletonList(rows: 4), reduceMotion: true));
    expect(find.byType(SkeletonRow), findsNWidgets(4));

    await tester.pumpWidget(harness(const SkeletonList(rows: 3, withHero: true),
        reduceMotion: true));
    expect(find.byType(SkeletonRow), findsNWidgets(3));
  });

  testWidgets('reduce-motion keeps the shimmer static (no pending frames)',
      (tester) async {
    await tester.pumpWidget(harness(const SkeletonRow(), reduceMotion: true));
    await tester.pump(const Duration(seconds: 2));
    // With animations disabled the pulse controller is stopped — settling
    // must terminate instead of chasing an endless repeat().
    await tester.pumpAndSettle();
  });
}
