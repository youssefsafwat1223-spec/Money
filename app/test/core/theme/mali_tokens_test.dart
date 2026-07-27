import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/mali_tokens.dart';

void main() {
  group('MaliTokens.dark', () {
    test('canvas is true black', () {
      expect(MaliTokens.dark.canvas, const Color(0xFF000000));
    });

    test('surface hierarchy increases in opacity: raised < floating < glass',
        () {
      expect(MaliTokens.dark.surfaceRaised.a,
          lessThan(MaliTokens.dark.surfaceFloating.a));
      expect(MaliTokens.dark.surfaceFloating.a,
          lessThan(MaliTokens.dark.surfaceGlassFill.a));
    });

    test('text-on-canvas contrast decreases: primary > secondary > muted', () {
      expect(MaliTokens.dark.textOnCanvasPrimary.a,
          greaterThan(MaliTokens.dark.textOnCanvasSecondary.a));
      expect(MaliTokens.dark.textOnCanvasSecondary.a,
          greaterThan(MaliTokens.dark.textOnCanvasMuted.a));
    });

    test('ring indeterminate state is muted, not a real value color', () {
      expect(MaliTokens.dark.ringIndeterminate.a, lessThan(1.0));
      expect(MaliTokens.dark.ringTrackNeutral.a,
          lessThan(MaliTokens.dark.ringIndeterminate.a));
    });
  });

  group('MaliTokens.light', () {
    test('canvas is a light off-white, not black', () {
      expect(MaliTokens.light.canvas, isNot(const Color(0xFF000000)));
      expect(MaliTokens.light.canvas.computeLuminance(), greaterThan(0.8));
    });

    test('primary text is dark ink (readable on the light canvas)', () {
      expect(MaliTokens.light.textOnCanvasPrimary.computeLuminance(),
          lessThan(0.2));
    });
  });

  test('accent gradient is two restrained blue/indigo stops (mode-invariant)',
      () {
    expect(MaliTokens.accentGradient.colors, hasLength(2));
    expect(MaliTokens.accentGradient.colors.first, MaliTokens.accentStart);
    expect(MaliTokens.accentGradient.colors.last, MaliTokens.accentEnd);
  });

  group('MaliTokens.of', () {
    testWidgets('resolves dark under a dark theme, light under a light theme',
        (tester) async {
      late MaliTokens resolved;
      Future<void> pump(Brightness b) async {
        await tester.pumpWidget(
          MaterialApp(
            // A fresh subtree per brightness avoids MaterialApp's default
            // AnimatedTheme lerping from the previous theme (which would leave
            // the interpolated brightness at the old value for a frame).
            key: ValueKey(b),
            theme: ThemeData(brightness: b),
            home: Builder(
              builder: (context) {
                resolved = MaliTokens.of(context);
                return const SizedBox();
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await pump(Brightness.dark);
      expect(resolved.canvas, MaliTokens.dark.canvas);
      await pump(Brightness.light);
      expect(resolved.canvas, MaliTokens.light.canvas);
    });
  });
}
