import 'package:flutter/material.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:money_companion/features/onboarding/story_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

Widget _app({Locale locale = const Locale('ar')}) {
  final router = GoRouter(
    initialLocation: '/welcome',
    routes: [
      GoRoute(
        path: '/welcome',
        builder: (context, state) => const OnboardingStoryScreen(),
      ),
      GoRoute(
        path: '/onboarding/brand',
        builder: (context, state) => const Scaffold(body: Text('BRAND')),
      ),
    ],
  );
  return MaterialApp.router(
    routerConfig: router,
    theme: AppTheme.light,
    darkTheme: AppTheme.dark,
    locale: locale,
    supportedLocales: AppL10n.supportedLocales,
    localizationsDelegates: const [
      ...AppL10n.localizationsDelegates,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    builder: (context, child) => MediaQuery(
      data: const MediaQueryData(disableAnimations: true),
      child: child!,
    ),
  );
}

void main() {
  Future<void> setSize(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('all four illustrated pages advance before the original brand route', (tester) async {
    await setSize(tester, const Size(390, 844));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    final titles = ['فلوسك واضحة… من غير مجهود', 'عملياتك من رسائل البنك',
      'ميزانية تنبهك قبل التجاوز', 'خصوصيتك قبل أي حاجة'];
    for (var page = 0; page < 4; page++) {
      expect(find.text(titles[page]), findsOneWidget);
      expect(find.bySemanticsLabel('الصفحة ${page + 1} من 4'), findsOneWidget);
      expect(find.text('BRAND'), findsNothing);
      await tester.tap(find.text(page == 3 ? 'ابدأ مع قِرش' : 'كمّل'));
      await tester.pumpAndSettle();
    }
    expect(find.text('BRAND'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('skip keeps the existing brand handoff', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    await tester.tap(find.text('تخطّي'));
    await tester.pumpAndSettle();
    expect(find.text('BRAND'), findsOneWidget);
  });

  testWidgets('RTL swipe and Back revisit the actual illustrated page', (tester) async {
    await setSize(tester, const Size(390, 844));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    await tester.drag(find.byType(PageView), const Offset(500, 0));
    await tester.pumpAndSettle();
    expect(find.text('عملياتك من رسائل البنك'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_back_ios_new));
    await tester.pumpAndSettle();
    expect(find.text('فلوسك واضحة… من غير مجهود'), findsOneWidget);
  });

  testWidgets('English copy remains LTR and consent is not granted by the intro', (tester) async {
    await setSize(tester, const Size(390, 844));
    await tester.pumpWidget(_app(locale: const Locale('en')));
    await tester.pumpAndSettle();
    expect(find.text('Your money, clear — without the effort'), findsOneWidget);
    expect(Directionality.of(tester.element(find.byType(PageView))), TextDirection.ltr);
    expect(find.byType(Switch), findsNothing);
    expect(find.text('Continue'), findsOneWidget);
    expect(find.byKey(const ValueKey('onboarding-language')), findsOneWidget);
  });

  testWidgets('small-phone content scrolls without overflow', (tester) async {
    await setSize(tester, const Size(320, 568));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    for (var page = 0; page < 4; page++) {
      expect(tester.takeException(), isNull);
      if (page < 3) {
        await tester.tap(find.text('كمّل'));
        await tester.pumpAndSettle();
      }
    }
  });
}
