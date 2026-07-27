import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/glass_surface.dart';

void main() {
  testWidgets('frosts with a backdrop blur and renders its child',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        // GlassSurface reads the AppColors extension (c.surface) to mirror the
        // nav's recipe exactly, so the app theme must be present.
        theme: AppTheme.dark,
        home: const Scaffold(body: GlassSurface(child: Text('حسابي'))),
      ),
    );
    expect(find.byType(BackdropFilter), findsAtLeastNWidgets(1));
    expect(find.text('حسابي'), findsOneWidget);
  });
}
