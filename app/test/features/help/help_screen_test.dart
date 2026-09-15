import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/help/help_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

/// V1 guidance, Layer B (charter: REQUIRED_PRODUCT_CHANGE_5).
///
/// The Help surface is the one screen whose entire job is to be readable, so it
/// is asserted in BOTH languages and BOTH directions rather than merely compiled.
Widget _host(Locale locale) => MaterialApp(
      locale: locale,
      localizationsDelegates: const [
        ...AppL10n.localizationsDelegates,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppL10n.supportedLocales,
      // The scaffold reads design tokens off the theme extension; without the
      // real theme the screen builds into nothing.
      theme: AppTheme.dark,
      home: const HelpScreen(),
    );

void main() {
  testWidgets('renders in Arabic, right-to-left', (tester) async {
    await tester.pumpWidget(_host(const Locale('ar')));
    await tester.pumpAndSettle();

    expect(find.text('كيف تستخدم قِرش'), findsWidgets);
    expect(find.text('الأساسيات'), findsOneWidget);
    // Below the fold — a ListView does not build off-screen children, so the
    // entry has to be scrolled to rather than merely looked for.
    await tester.scrollUntilVisible(find.text('التقرير السنوي'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('التقرير السنوي'), findsOneWidget);
    expect(
      Directionality.of(tester.element(find.byType(ListView))),
      TextDirection.rtl,
    );
  });

  testWidgets('renders in English, left-to-right', (tester) async {
    await tester.pumpWidget(_host(const Locale('en')));
    await tester.pumpAndSettle();

    expect(find.text('How to use Qirsh'), findsWidgets);
    expect(find.text('Basics'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('The annual report'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('The annual report'), findsOneWidget);
    expect(
      Directionality.of(tester.element(find.byType(ListView))),
      TextDirection.ltr,
    );
  });

  testWidgets('covers every topic the charter names', (tester) async {
    // Guidance that omits the thing a user is stuck on is not guidance. These
    // are the surfaces the V1 contract calls out by name.
    await tester.pumpWidget(_host(const Locale('en')));
    await tester.pumpAndSettle();

    for (final topic in [
      'Record a transaction',
      'Smart Inbox',
      'Changing the period',
      'The annual report',
      'Accounts and cards',
      'Budgets',
      'Goals',
      'You control your data',
      'Backup and restore',
    ]) {
      // Scroll each into view: absence from the viewport is not absence from
      // the guide, and asserting without scrolling would test the fold, not the
      // content.
      await tester.scrollUntilVisible(find.text(topic), 200,
          scrollable: find.byType(Scrollable).first);
      expect(find.text(topic), findsOneWidget, reason: topic);
    }
  });

  testWidgets('scrolls without overflowing on a small screen', (tester) async {
    // A guide that overflows is unreadable exactly when it is needed.
    tester.view.physicalSize = const Size(320 * 3, 568 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(const Locale('ar')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
