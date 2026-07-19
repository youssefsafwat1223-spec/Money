import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/features/settings/data_transfer_screen.dart';
import 'package:money_companion/core/theme/app_theme.dart';

void main() {
  testWidgets('shows the three portability entry points and privacy warning',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [accountsProvider.overrideWith((ref) async => const [])],
      child:
          MaterialApp(theme: AppTheme.light, home: const DataTransferScreen()),
    ));
    await tester.pump();

    expect(find.text('استيراد ملف'), findsOneWidget);
    expect(find.text('تصدير العمليات CSV'), findsOneWidget);
    expect(find.text('تصدير كل بيانات قرش ZIP'), findsOneWidget);
    expect(find.textContaining('رسائل البنك الخام'), findsOneWidget);
  });

  testWidgets('replace confirmation owns its controller through route teardown',
      (tester) async {
    bool? confirmed;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                confirmed = await showReplaceConfirmationDialog(context);
              },
              child: const Text('open replace'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open replace'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'استبدال');
    await tester.tap(find.text('تأكيد'));
    await tester.pumpAndSettle();

    expect(confirmed, isTrue);
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
