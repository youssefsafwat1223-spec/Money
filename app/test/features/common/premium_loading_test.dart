import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/common/premium_loading.dart';

void main() {
  testWidgets('first screen load shows a spinner instead of card skeletons',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: const Scaffold(
          body: FirstLoadPlaceholder(cardCount: 5),
        ),
      ),
    );

    expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
    expect(find.byType(PremiumSkeletonPage), findsNothing);
  });
}
