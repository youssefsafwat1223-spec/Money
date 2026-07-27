import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/startup/bootstrap_runner.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/app/startup_loading_screen.dart';

Widget _app(Widget child) {
  return MaterialApp(
    theme: AppTheme.light,
    home: child,
  );
}

void main() {
  testWidgets('shows the loading body with a spinner when there is no error',
      (tester) async {
    await tester.pumpWidget(_app(StartupLoadingScreen(onRetry: () {})));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('جاري تجهيز التطبيق...'), findsOneWidget);
    expect(find.text('إعادة المحاولة'), findsNothing);
  });

  testWidgets('shows the generic retry state for a non-timeout error',
      (tester) async {
    var retried = false;
    await tester.pumpWidget(_app(StartupLoadingScreen(
      error: Exception('boom'),
      onRetry: () => retried = true,
    )));
    await tester.pump();

    expect(find.text('تعذّر تجهيز التطبيق'), findsOneWidget);
    expect(find.text('إعادة المحاولة'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await tester.tap(find.text('إعادة المحاولة'));
    expect(retried, isTrue);
  });

  testWidgets('shows timeout-specific copy for a BootstrapTimeoutException',
      (tester) async {
    await tester.pumpWidget(_app(StartupLoadingScreen(
      error: const BootstrapTimeoutException('database_open'),
      lastStep: 'database_open',
      onRetry: () {},
    )));
    await tester.pump();

    expect(find.text('استغرق التجهيز وقتاً أطول من المتوقع'), findsOneWidget);
    expect(find.textContaining('database_open'), findsOneWidget);
  });

  testWidgets('does not show a diagnostic identifier when lastStep is null',
      (tester) async {
    await tester.pumpWidget(_app(StartupLoadingScreen(
      error: Exception('boom'),
      onRetry: () {},
    )));
    await tester.pump();

    expect(find.textContaining('معرّف:'), findsNothing);
  });
}
