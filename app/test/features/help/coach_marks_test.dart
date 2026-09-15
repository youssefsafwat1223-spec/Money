import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/utils/app_lucide_icons.dart';
import 'package:money_companion/features/help/coach_marks.dart';
import 'package:money_companion/l10n/app_localizations.dart';

/// V1 guidance, Layer A (charter: REQUIRED_PRODUCT_CHANGE_5).
///
/// These cover the tour widget itself. The once-only persistence lives in
/// AppSession and needs platform secure storage, so it is asserted in the
/// session tests rather than faked here — a fake would only prove the fake.
Widget _host(Locale locale, Widget child) => MaterialApp(
      locale: locale,
      localizationsDelegates: const [
        ...AppL10n.localizationsDelegates,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppL10n.supportedLocales,
      theme: AppTheme.dark,
      home: child,
    );

List<CoachMark> _marks() => const [
      CoachMark(icon: AppLucideIcons.plus, title: 'One', body: 'First step'),
      CoachMark(icon: AppLucideIcons.inbox, title: 'Two', body: 'Second step'),
    ];

Future<void> _openTour(WidgetTester tester, Locale locale) async {
  await tester.pumpWidget(_host(
    locale,
    Builder(
      builder: (context) => TextButton(
        onPressed: () => showDialog<void>(
          context: context,
          builder: (_) => CoachMarkTourForTest(marks: _marks()),
        ),
        child: const Text('open'),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('advances through every step, then finishes', (tester) async {
    await _openTour(tester, const Locale('en'));

    expect(find.text('One'), findsOneWidget);
    expect(find.text('Next'), findsOneWidget);

    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();

    // Second step, and the CTA becomes the terminal one — a tour that never
    // says it has ended reads as broken.
    expect(find.text('Two'), findsOneWidget);
    expect(find.text('Next'), findsNothing);
    expect(find.text('Got it'), findsOneWidget);

    await tester.tap(find.text('Got it'));
    await tester.pumpAndSettle();
    expect(find.text('Two'), findsNothing);
  });

  testWidgets('skip closes it immediately from the first step', (tester) async {
    await _openTour(tester, const Locale('en'));
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    expect(find.text('One'), findsNothing);
  });

  testWidgets('renders in Arabic, right-to-left', (tester) async {
    await _openTour(tester, const Locale('ar'));
    expect(find.text('التالي'), findsOneWidget);
    expect(find.text('تخطّي'), findsOneWidget);
    expect(
      Directionality.of(tester.element(find.text('التالي'))),
      TextDirection.rtl,
    );
  });

  testWidgets('the dashboard tour is populated and localised', (tester) async {
    late List<CoachMark> marks;
    await tester.pumpWidget(_host(
      const Locale('en'),
      Builder(builder: (context) {
        marks = dashboardCoachMarks(context);
        return const SizedBox();
      }),
    ));
    await tester.pumpAndSettle();

    expect(marks, isNotEmpty);
    for (final mark in marks) {
      expect(mark.title.trim(), isNotEmpty);
      expect(mark.body.trim(), isNotEmpty);
    }
  });

  test('coach mark ids are stable and not derived from copy', () {
    // The id is the identity. Deriving it from translated text would re-show
    // the whole tour every time a translator edited a word.
    expect(CoachMarkIds.dashboard, 'dashboard.v1');
  });
}
