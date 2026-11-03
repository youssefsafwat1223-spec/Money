import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:money_companion/core/theme/app_colors.dart';
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

  testWidgets('every variant renders its child; chrome blurs and form sheets stay opaque',
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
        variant == MaliGlassVariant.headerAction || variant == MaliGlassVariant.sheet
            ? findsNothing
            : findsOneWidget,
      );
    }
  });

  testWidgets('variants pick their design radius; radius overrides it',
      (tester) async {
    const expected = {
      MaliGlassVariant.pill: BorderRadius.all(Radius.circular(999)),
      // The approved prototype's 20px card radius and native navigation pill.
      MaliGlassVariant.card: BorderRadius.all(Radius.circular(20)),
      MaliGlassVariant.navigation: BorderRadius.all(Radius.circular(999)),
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

  testWidgets('HTML form sheets are neutral and opaque in both themes', (tester) async {
    for (final theme in [AppTheme.light, AppTheme.dark]) {
      await tester.pumpWidget(harness(const MaliGlass(
        variant: MaliGlassVariant.sheet, nativeMaterial: true, child: Text('x'),
      ), theme: theme));
      await tester.pumpAndSettle();
      final colors = tester.widgetList<ColoredBox>(find.descendant(
        of: find.byType(MaliGlass), matching: find.byType(ColoredBox))).map((w) => w.color);
      expect(colors, contains(theme.extension<AppColors>()!.surface));
      expect(find.byType(NativeGlassBackdrop), findsNothing);
      expect(find.byType(BackdropFilter), findsNothing);
      expect(find.text('x'), findsOneWidget);
    }
  });

  testWidgets(
      'generic MaliGlass never selects the native tier — even on iOS 26 '
      'with native support present', (tester) async {
    // Simulate "iOS 26 with the native capability available". The platform
    // override is a foundation debug variable — reset in the body (finally),
    // before flutter_test's invariant check.
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    NativeGlassSupport.debugOverride = true;
    addTearDown(() => NativeGlassSupport.debugOverride = null);
    try {
      for (final variant in [
        MaliGlassVariant.card,
        MaliGlassVariant.pill,
        MaliGlassVariant.navigation,
      ]) {
        await tester.pumpWidget(
          harness(MaliGlass(variant: variant, child: const Text('x'))),
        );
        // Native ownership stays outside generic MaliGlass: no platform-view
        // backdrop; the Qirsh frost path renders instead.
        expect(find.byType(NativeGlassBackdrop), findsNothing);
        expect(find.byType(BackdropFilter), findsOneWidget);
        expect(find.text('x'), findsOneWidget);
      }
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
      'an explicit native host (nativeMaterial) renders Apple glass when '
      'supported, and the Flutter frost when not', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => NativeGlassSupport.debugOverride = null);
    try {
      NativeGlassSupport.debugOverride = true;
      await tester.pumpWidget(harness(const MaliGlass(
        variant: MaliGlassVariant.card,
        nativeMaterial: true,
        child: Text('x'),
      )));
      expect(find.byType(NativeGlassBackdrop), findsOneWidget);
      expect(find.byType(BackdropFilter), findsNothing);
      expect(find.text('x'), findsOneWidget);

      NativeGlassSupport.debugOverride = false;
      await tester.pumpWidget(harness(const MaliGlass(
        key: ValueKey('unsupported'),
        variant: MaliGlassVariant.card,
        nativeMaterial: true,
        child: Text('x'),
      )));
      expect(find.byType(NativeGlassBackdrop), findsNothing);
      expect(find.byType(BackdropFilter), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
      'Increase Contrast keeps an explicit native host on Apple glass — '
      'the system material adapts itself', (tester) async {
    NativeGlassSupport.debugOverride = true;
    addTearDown(() => NativeGlassSupport.debugOverride = null);
    await tester.pumpWidget(harness(
      const MaliGlass(
        variant: MaliGlassVariant.pill,
        nativeMaterial: true,
        child: Text('x'),
      ),
      mediaQuery: (data) => data.copyWith(highContrast: true),
    ));
    expect(find.byType(NativeGlassBackdrop), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets(
      'Reduce Transparency turns Dart-drawn glass opaque and leaves native '
      'glass to the system', (tester) async {
    addTearDown(() => NativeGlassSupport.debugOverride = null);
    NativeGlassSupport.debugOverride = false;
    NativeGlassSupport.reduceTransparency.value = true;
    await tester.pumpWidget(harness(const MaliGlass(
      variant: MaliGlassVariant.card,
      nativeMaterial: true,
      child: Text('x'),
    )));
    expect(find.byType(BackdropFilter), findsNothing);
    expect(fillDecoration(tester), isNull);

    // Live: switching it off restores the translucent material, no restart.
    NativeGlassSupport.reduceTransparency.value = false;
    await tester.pump();
    expect(find.byType(BackdropFilter), findsOneWidget);

    NativeGlassSupport.debugOverride = true;
    NativeGlassSupport.reduceTransparency.value = true;
    await tester.pumpWidget(harness(const MaliGlass(
      key: ValueKey('native'),
      variant: MaliGlassVariant.card,
      nativeMaterial: true,
      child: Text('x'),
    )));
    expect(find.byType(NativeGlassBackdrop), findsOneWidget);
  });

  testWidgets(
      'native tier paints nothing over Apple glass; tint goes to the '
      'material', (tester) async {
    NativeGlassSupport.debugOverride = true;
    addTearDown(() => NativeGlassSupport.debugOverride = null);
    const tint = Color(0x24FF0000);
    await tester.pumpWidget(harness(const MaliGlass(
      variant: MaliGlassVariant.card,
      nativeMaterial: true,
      tint: tint,
      child: Text('x'),
    )));
    final backdrop =
        tester.widget<NativeGlassBackdrop>(find.byType(NativeGlassBackdrop));
    expect(backdrop.tint, tint);
    // No Dart-drawn wash, gradient fill or tint layer above the platform view.
    expect(
      find.descendant(
        of: find.byType(MaliGlass),
        matching: find.byType(ColoredBox),
      ),
      findsNothing,
    );
    expect(fillDecoration(tester), isNull);
    for (final box in tester.widgetList<DecoratedBox>(
      find.descendant(
        of: find.byType(MaliGlass),
        matching: find.byType(DecoratedBox),
      ),
    )) {
      expect((box.decoration as BoxDecoration).color, isNot(tint));
    }
  });

  testWidgets('frost tiers paint the tint as a wash', (tester) async {
    NativeGlassSupport.debugOverride = false;
    addTearDown(() => NativeGlassSupport.debugOverride = null);
    const tint = Color(0x24FF0000);
    await tester.pumpWidget(harness(const MaliGlass(
      nativeMaterial: true,
      tint: tint,
      child: Text('x'),
    )));
    expect(
      tester.widgetList<DecoratedBox>(find.byType(DecoratedBox)).any((b) =>
          b.decoration is BoxDecoration &&
          (b.decoration as BoxDecoration).color == tint),
      isTrue,
    );
  });

  testWidgets(
      'the native backdrop follows a theme switch without a restart '
      '(re-keyed platform view)', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    NativeGlassSupport.debugOverride = true;
    addTearDown(() => NativeGlassSupport.debugOverride = null);
    try {
      Key? keyFor(ThemeData theme) =>
          tester.widget<UiKitView>(find.byType(UiKitView)).key;

      const glass = MaliGlass(nativeMaterial: true, child: Text('x'));
      await tester.pumpWidget(harness(glass, theme: AppTheme.light));
      final lightKey = keyFor(AppTheme.light);
      expect(
        (tester.widget<UiKitView>(find.byType(UiKitView)).creationParams
            as Map)['dark'],
        isFalse,
      );
      await tester.pumpWidget(harness(glass, theme: AppTheme.dark));
      await tester.pumpAndSettle(); // MaterialApp animates the theme change.
      expect(keyFor(AppTheme.dark), isNot(lightKey));
      expect(
        (tester.widget<UiKitView>(find.byType(UiKitView)).creationParams
            as Map)['dark'],
        isTrue,
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
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
