import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/design_gallery/design_gallery_screen.dart';

void main() {
  testWidgets('renders every section without throwing', (tester) async {
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.light, home: const DesignGalleryScreen()),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Mali Design Gallery'), findsOneWidget);
  });

  testWidgets('exercises mixed Arabic/Latin currency typography together',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.light, home: const DesignGalleryScreen()),
    );
    await tester.pumpAndSettle();

    // Arabic-currency tabular amount.
    expect(find.text('48,250.00 ج.م'), findsOneWidget);
    // Latin-currency-code amount, same screen, RTL context.
    expect(find.text('25,420 EGP'), findsOneWidget);
    // Signed amount + Arabic merchant name in one line.
    expect(find.text('−320.00 · نون تسوّق'), findsOneWidget);
  });

  testWidgets('shows the Safe-to-Spend ring concept with plain-language text',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.light, home: const DesignGalleryScreen()),
    );
    await tester.pumpAndSettle();

    expect(find.text('مصروفك أعلى من المعتاد'), findsOneWidget);
    expect(find.text('وضعك مستقر'), findsOneWidget);
    expect(find.text('بيانات غير كافية بعد'), findsOneWidget);
  });

  // Regression: the RingProgress demo row overflowed on a real device
  // (content width 342px, standard 390pt-wide iPhone minus MaliScreen's 24px
  // padding) because three default-size (120px) rings in a Row with no
  // Expanded need 360px alone. Pump at both the exact failing width and the
  // narrower iPhone SE width so this can't silently regress.
  for (final size in [
    (name: 'iPhone standard (390x844)', size: const Size(390, 844)),
    (name: 'iPhone SE (375x667)', size: const Size(375, 667)),
  ]) {
    testWidgets('no overflow on ${size.name}', (tester) async {
      final view = tester.view;
      view.physicalSize = size.size * view.devicePixelRatio;
      addTearDown(view.resetPhysicalSize);
      addTearDown(view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.light, home: const DesignGalleryScreen()),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  }
}
