import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_typography.dart';

void main() {
  // B2-D — BEHAVIORAL/structural font contract (replaces the old source-text
  // test that asserted the literal `GoogleFonts.alexandria` spelling and thereby
  // cemented the runtime-fetch anti-pattern). These check the rendered/declared
  // font CONFIGURATION, so a formatting-only refactor cannot fail the contract.
  group('IBM Plex Sans Arabic bundled font contract', () {
    test(
        'pubspec registers ONE IBMPlexSansArabic family with the '
        '400/500/600/700 weight→file mapping and no runtime google_fonts', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec, contains('family: IBMPlexSansArabic'));
      for (final pair in const [
        (400, 'IBMPlexSansArabic-Regular.ttf'),
        (500, 'IBMPlexSansArabic-Medium.ttf'),
        (600, 'IBMPlexSansArabic-SemiBold.ttf'),
        (700, 'IBMPlexSansArabic-Bold.ttf'),
      ]) {
        expect(pubspec, contains('asset: assets/fonts/${pair.$2}'),
            reason: 'weight ${pair.$1} asset declared');
        expect(pubspec, contains('weight: ${pair.$1}'));
      }
      // The bundled fallback families stay registered too.
      expect(pubspec, contains('family: Vazirmatn'));
      expect(pubspec, contains('family: Alexandria'));
      // No runtime GoogleFonts dependency remains — nothing can fetch at runtime.
      expect(pubspec, isNot(contains('google_fonts:')));
    });

    test('custom() uses the bundled IBMPlexSansArabic family + fallbacks', () {
      final s =
          AppTypography.custom(size: 16, weight: FontWeight.w400, height: 1.5);
      expect(s.fontFamily, 'IBMPlexSansArabic');
      expect(s.fontFamilyFallback,
          containsAllInOrder(['Vazirmatn', 'Alexandria']));
    });

    test('every requested weight is preserved on the primary family', () {
      // Weight resolution to the matching bundled TTF is Flutter-engine work
      // driven by the pubspec mapping above; at the style layer the requested
      // FontWeight is carried through unchanged for all four mapped weights.
      for (final w in const [
        FontWeight.w400,
        FontWeight.w500,
        FontWeight.w600,
        FontWeight.w700,
      ]) {
        final s = AppTypography.custom(size: 16, weight: w, height: 1.5);
        expect(s.fontFamily, 'IBMPlexSansArabic');
        expect(s.fontWeight, w);
      }
    });

    // UX-002 — these pin the APPROVED scale (`BRAND_AND_DESIGN_SYSTEM.md` §7),
    // not whatever the file happened to contain. Title-2 and Headline are
    // SemiBold 600 there; the implementation had drifted to Bold 700, and that
    // drift is what this test previously froze in place. A snapshot of the
    // current value protects nothing — it only makes the next correction look
    // like a regression.
    test('named styles match the approved spec: size/weight/height/features',
        () {
      const c = Color(0xFF000000);
      final body = AppTypography.body(c);
      expect((body.fontFamily, body.fontSize, body.fontWeight, body.height),
          ('IBMPlexSansArabic', 16.0, FontWeight.w400, 1.50));
      final t2 = AppTypography.title2(c);
      // §7 Title-2: SemiBold. (Size is one step below the spec's 22 by the
      // documented density deviation — see app_typography.dart.)
      expect((t2.fontFamily, t2.fontSize, t2.fontWeight, t2.height),
          ('IBMPlexSansArabic', 20.0, FontWeight.w600, 1.24));
      final hero = AppTypography.amountHero(c);
      expect(hero.fontFamily, 'IBMPlexSansArabic');
      expect(hero.fontSize, 40);
      expect(hero.fontFeatures, contains(const FontFeature.tabularFigures()));
    });

    test('textTheme maps Material slots to the primary family with metrics',
        () {
      final theme = AppTypography.textTheme(const Color(0xFF111111));
      expect(theme.bodyLarge!.fontFamily, 'IBMPlexSansArabic');
      expect(theme.bodyLarge!.fontSize, 16);
      expect(theme.headlineMedium!.fontFamily, 'IBMPlexSansArabic'); // title2
      expect(theme.headlineMedium!.fontSize, 20);
      expect(theme.headlineMedium!.fontWeight, FontWeight.w600); // §7 SemiBold
    });

    testWidgets('offline: Arabic + English render with the bundled family, no network',
        (tester) async {
      // No google_fonts import remains in the typography path, so no runtime
      // fetch is even possible — a bundled family renders on a cold offline
      // launch. Both scripts resolve without exception.
      await tester.pumpWidget(MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            body: Column(children: [
              Text('مصروفات اليوم',
                  style: AppTypography.body(const Color(0xFF000000))),
              Text('Balance 1,250.00 EGP',
                  style: AppTypography.amountSmall(const Color(0xFF000000))),
            ]),
          ),
        ),
      ));
      expect(tester.takeException(), isNull);
      expect(tester.widget<Text>(find.text('مصروفات اليوم')).style!.fontFamily,
          'IBMPlexSansArabic');
      expect(find.text('Balance 1,250.00 EGP'), findsOneWidget);
    });
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      'Arabic typography renders without overflow at 320px and 1.25x in ${brightness.name}',
      (tester) async {
        tester.view.physicalSize = const Size(320, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        final color =
            brightness == Brightness.light ? Colors.black : Colors.white;
        final typographyTheme = ThemeData(
          brightness: brightness,
          fontFamily: 'Alexandria',
          textTheme: TextTheme(
            displayLarge: TextStyle(
              fontFamily: 'Alexandria',
              fontSize: 36,
              fontWeight: FontWeight.w700,
              height: 1.06,
              letterSpacing: 0,
              color: color,
            ),
            bodyLarge: TextStyle(
              fontFamily: 'Alexandria',
              fontSize: 16,
              fontWeight: FontWeight.w400,
              height: 1.55,
              letterSpacing: 0,
              color: color,
            ),
            titleMedium: TextStyle(
              fontFamily: 'Alexandria',
              fontSize: 18,
              fontWeight: FontWeight.w600,
              height: 1.3,
              letterSpacing: 0,
              color: color,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        );

        await tester.pumpWidget(
          MaterialApp(
            theme: typographyTheme,
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(320, 720),
                textScaler: TextScaler.linear(1.25),
              ),
              child: Directionality(
                textDirection: TextDirection.rtl,
                child: Scaffold(
                  body: SafeArea(
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        Text(
                          'متحمّسين نبدأ معك لإدارة مالية أوضح وأسهل',
                          style: typographyTheme.textTheme.displayLarge,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'قِرش يساعدك على فهم مصروفاتك واتخاذ قراراتك بثقة.',
                          style: typographyTheme.textTheme.bodyLarge,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'مصروفات اليوم 12,450.75 EGP',
                          style: typographyTheme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 16),
                        const FilledButton(
                          onPressed: null,
                          child: Text('ابدأ رحلتك مع Qirsh'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        expect(tester.takeException(), isNull);
        expect(find.textContaining('متحمّسين'), findsOneWidget);
        expect(find.textContaining('12,450.75 EGP'), findsOneWidget);
      },
    );
  }
}
