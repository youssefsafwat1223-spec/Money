import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/mali_tokens.dart';
import 'package:money_companion/core/theme/widgets/mali_glass.dart';
import 'package:money_companion/core/theme/widgets/native_glass.dart';

void main() {
  Widget harness(
    Widget child, {
    ThemeData? theme,
    MediaQueryData Function(MediaQueryData)? mediaQuery,
  }) {
    Widget body = Center(child: child);
    if (mediaQuery != null) {
      final inner = body;
      body = Builder(
        builder: (context) => MediaQuery(
          data: mediaQuery(MediaQuery.of(context)),
          child: inner,
        ),
      );
    }
    return MaterialApp(
      theme: theme ?? AppTheme.light,
      home: Scaffold(body: body),
    );
  }

  BoxDecoration? fillDecoration(WidgetTester tester) {
    for (final box in tester.widgetList<DecoratedBox>(
      find.byType(DecoratedBox),
    )) {
      final d = box.decoration;
      if (d is BoxDecoration && d.gradient is LinearGradient) {
        final g = d.gradient! as LinearGradient;
        if (g.colors.length == 2) return d;
      }
    }
    return null;
  }

  testWidgets('every variant renders its child; all blur except headerAction',
      (tester) async {
    for (final variant in MaliGlassVariant.values) {
      await tester.pumpWidget(
        harness(MaliGlass(variant: variant, child: const Text('content'))),
      );
      expect(find.text('content'), findsOneWidget);
      // headerAction sits on the opaque blue header gradient — blurring a
      // flat gradient is invisible, so it deliberately skips the filter.
      expect(
        find.byType(BackdropFilter),
        variant == MaliGlassVariant.headerAction
            ? findsNothing
            : findsOneWidget,
      );
    }
  });

  testWidgets('variants pick their design radius; radius overrides it',
      (tester) async {
    const expected = {
      MaliGlassVariant.pill: BorderRadius.all(Radius.circular(999)),
      MaliGlassVariant.card: BorderRadius.all(Radius.circular(28)),
      MaliGlassVariant.navigation: BorderRadius.all(Radius.circular(26)),
      MaliGlassVariant.sheet: BorderRadius.vertical(top: Radius.circular(28)),
      MaliGlassVariant.headerAction: BorderRadius.all(Radius.circular(999)),
    };
    for (final entry in expected.entries) {
      await tester.pumpWidget(
        harness(MaliGlass(variant: entry.key, child: const Text('x'))),
      );
      final clip = tester.widget<ClipRRect>(find.byType(ClipRRect));
      expect(clip.borderRadius, entry.value);
    }
    await tester.pumpWidget(
      harness(const MaliGlass(
        variant: MaliGlassVariant.card,
        radius: 0,
        child: Text('x'),
      )),
    );
    final clip = tester.widget<ClipRRect>(find.byType(ClipRRect));
    expect(clip.borderRadius, BorderRadius.circular(0));
  });

  testWidgets('onTap fires and exposes button semantics', (tester) async {
    final handle = tester.ensureSemantics();
    var taps = 0;
    await tester.pumpWidget(
      harness(MaliGlass(
        variant: MaliGlassVariant.pill,
        onTap: () => taps++,
        child: const Text('go'),
      )),
    );
    await tester.tap(find.text('go'));
    expect(taps, 1);
    expect(
      tester.getSemantics(find.byType(InkWell)),
      containsSemantics(isButton: true, hasTapAction: true, isFocusable: true),
    );
    handle.dispose();
  });

  testWidgets('enabled: false ignores taps and drops the ink layer',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      harness(MaliGlass(
        variant: MaliGlassVariant.pill,
        onTap: () => taps++,
        enabled: false,
        child: const Text('go'),
      )),
    );
    await tester.tap(find.text('go'), warnIfMissed: false);
    expect(taps, 0);
    expect(find.byType(InkWell), findsNothing);
    expect(find.byType(AnimatedScale), findsNothing);
  });

  testWidgets('press applies the reference 0.96 active scale and releases',
      (tester) async {
    await tester.pumpWidget(
      harness(MaliGlass(
        variant: MaliGlassVariant.pill,
        onTap: () {},
        child: const Text('go'),
      )),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('go')),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale,
      0.96,
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(
      tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale,
      1.0,
    );
  });

  testWidgets('reduce-motion keeps the surface static while pressed',
      (tester) async {
    await tester.pumpWidget(
      harness(
        MaliGlass(
          variant: MaliGlassVariant.pill,
          onTap: () {},
          child: const Text('go'),
        ),
        mediaQuery: (data) => data.copyWith(disableAnimations: true),
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('go')),
    );
    await tester.pump(const Duration(milliseconds: 100));
    // No animation widgets at all under reduce-motion; surface stays static.
    expect(find.byType(AnimatedScale), findsNothing);
    expect(find.byType(AnimatedOpacity), findsNothing);
    await gesture.up();
    await tester.pump();
  });

  testWidgets('fill gradient resolves from the light tokens', (tester) async {
    await tester.pumpWidget(
      harness(const MaliGlass(
        variant: MaliGlassVariant.card,
        child: Text('x'),
      )),
    );
    final gradient = fillDecoration(tester)!.gradient! as LinearGradient;
    expect(gradient.colors, [
      MaliTokens.light.glassFillTop,
      MaliTokens.light.glassFillBottom,
    ]);
  });

  testWidgets('fill gradient resolves from the dark tokens', (tester) async {
    await tester.pumpWidget(
      harness(
        const MaliGlass(variant: MaliGlassVariant.card, child: Text('x')),
        theme: AppTheme.dark,
      ),
    );
    final gradient = fillDecoration(tester)!.gradient! as LinearGradient;
    expect(gradient.colors, [
      MaliTokens.dark.glassFillTop,
      MaliTokens.dark.glassFillBottom,
    ]);
  });

  testWidgets('sheet body keeps a legibility floor (forms never fully clear)',
      (tester) async {
    await tester.pumpWidget(
      harness(const MaliGlass(
        variant: MaliGlassVariant.sheet,
        child: Text('x'),
      )),
    );
    final gradient = fillDecoration(tester)!.gradient! as LinearGradient;
    expect(gradient.colors.last, MaliTokens.light.glassSheetFill);
    expect(gradient.colors.last.a, greaterThan(0.6));
  });

  testWidgets(
      'native glass (iOS 26) replaces the emulated layers with the platform '
      'view backdrop', (tester) async {
    NativeGlassSupport.debugOverride = true;
    addTearDown(() => NativeGlassSupport.debugOverride = null);
    await tester.pumpWidget(
      harness(const MaliGlass(
        variant: MaliGlassVariant.card,
        child: Text('x'),
      )),
    );
    expect(find.byType(NativeGlassBackdrop), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(fillDecoration(tester), isNull);
    expect(find.text('x'), findsOneWidget);
  });

  testWidgets('sheet keeps the drawn near-opaque body even with native glass',
      (tester) async {
    NativeGlassSupport.debugOverride = true;
    addTearDown(() => NativeGlassSupport.debugOverride = null);
    await tester.pumpWidget(
      harness(const MaliGlass(
        variant: MaliGlassVariant.sheet,
        child: Text('x'),
      )),
    );
    expect(find.byType(NativeGlassBackdrop), findsNothing);
    expect(find.byType(BackdropFilter), findsOneWidget);
  });

  testWidgets('high contrast renders opaque with no backdrop blur',
      (tester) async {
    await tester.pumpWidget(
      harness(
        const MaliGlass(variant: MaliGlassVariant.card, child: Text('x')),
        mediaQuery: (data) => data.copyWith(highContrast: true),
      ),
    );
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.text('x'), findsOneWidget);
    expect(fillDecoration(tester), isNull);
  });

  testWidgets(
      'refractive degrades silently to blurred glass when shader filters '
      'are unavailable', (tester) async {
    await tester.pumpWidget(
      harness(const MaliGlass(
        variant: MaliGlassVariant.card,
        refractive: true,
        child: Text('x'),
      )),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(find.text('x'), findsOneWidget);
  });
}
