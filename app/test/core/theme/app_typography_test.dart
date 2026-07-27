import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('centralized typography uses Alexandria (IBM Plex Sans fallback)', () {
    final source = File(
      'lib/core/theme/app_typography.dart',
    ).readAsStringSync();

    // Primary Arabic-first family is Alexandria; IBM Plex Sans stays as the
    // Latin fallback safety net.
    expect(source, contains('GoogleFonts.alexandria'));
    expect(source, contains('GoogleFonts.ibmPlexSans'));
    expect(source, contains('double letterSpacing = 0'));
    expect(source, contains('FontFeature.tabularFigures()'));
    expect(source, isNot(contains('GoogleFonts.inter')));
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
