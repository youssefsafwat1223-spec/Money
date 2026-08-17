import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/mali_glass.dart';
import 'package:money_companion/core/theme/widgets/mali_glass_advanced.dart';

const _advancedKey = ValueKey('MaliGlassAdvancedSurface');

void main() {
  Widget harness(Widget child, {MediaQueryData Function(MediaQueryData)? mq}) {
    Widget body = Center(child: child);
    if (mq != null) {
      final inner = body;
      body = Builder(
        builder: (context) =>
            MediaQuery(data: mq(MediaQuery.of(context)), child: inner),
      );
    }
    return MaterialApp(theme: AppTheme.light, home: Scaffold(body: body));
  }

  // The platform override is a foundation debug variable: flutter_test
  // verifies it is reset BEFORE tearDowns run, so tests must clear it at the
  // end of their own body (helper below guarantees it via finally).
  Future<void> onPlatform(
    TargetPlatform platform,
    Future<void> Function() body, {
    bool? shaderSupported,
  }) async {
    debugDefaultTargetPlatformOverride = platform;
    debugAdvancedShaderOverride = shaderSupported;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
      debugAdvancedShaderOverride = null;
    }
  }

  GlassTier resolve({
    bool advancedRequested = true,
    bool shaderSupported = true,
    bool platformAllowed = true,
    bool highContrast = false,
    bool nativeGlassActive = false,
  }) =>
      resolveGlassTier(
        advancedRequested: advancedRequested,
        shaderSupported: shaderSupported,
        platformAllowed: platformAllowed,
        highContrast: highContrast,
        nativeGlassActive: nativeGlassActive,
      );

  group(
      'resolveGlassTier matrix — the package is never reached outside the '
      'approved window', () {
    test('high contrast always wins with opaque', () {
      expect(resolve(highContrast: true, nativeGlassActive: true),
          GlassTier.opaque);
    });

    test('explicit native host wins over advanced', () {
      expect(resolve(nativeGlassActive: true), GlassTier.native);
    });

    test('advanced needs request AND shader AND platform', () {
      expect(resolve(), GlassTier.advanced);
      expect(resolve(shaderSupported: false), GlassTier.frost);
      expect(resolve(advancedRequested: false), GlassTier.frost);
      expect(resolve(platformAllowed: false), GlassTier.frost);
    });

    test('temporary Android gate is closed', () {
      expect(kAndroidAdvancedRefractionEnabled, isFalse,
          reason: 'Flip only after the real-device gate in '
              'docs/LIQUID_GLASS_PACKAGE.md passes.');
    });

    test('platform gate: Android blocked, iOS/macOS allowed', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(advancedTierAllowedOnPlatform, isFalse);
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(advancedTierAllowedOnPlatform, isTrue);
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      expect(advancedTierAllowedOnPlatform, isTrue);
      debugDefaultTargetPlatformOverride = null;
    });
  });

  testWidgets(
      'ANDROID GATE: shader-supported + opted-in still resolves to Qirsh '
      'frost while the device gate is closed', (tester) async {
    await onPlatform(TargetPlatform.android, shaderSupported: true, () async {
      await tester.pumpWidget(
        harness(const MaliGlass(
          variant: MaliGlassVariant.navigation,
          advancedRefraction: true,
          child: Text('nav'),
        )),
      );
      expect(tester.takeException(), isNull);
      expect(find.byKey(_advancedKey), findsNothing);
      expect(find.byType(BackdropFilter), findsOneWidget);
      expect(find.text('nav'), findsOneWidget);
    });
  });

  testWidgets(
      'iOS + supported + explicit opt-in selects the advanced package path',
      (tester) async {
    await onPlatform(TargetPlatform.iOS, shaderSupported: true, () async {
      await tester.pumpWidget(
        harness(const MaliGlass(
          variant: MaliGlassVariant.navigation,
          advancedRefraction: true,
          child: Text('nav'),
        )),
      );
      expect(tester.takeException(), isNull);
      expect(find.byKey(_advancedKey), findsOneWidget);
      expect(find.byType(BackdropFilter), findsNothing);
      expect(find.text('nav'), findsOneWidget);
    });
  });

  testWidgets('sheet refuses the advanced tier even when opted in',
      (tester) async {
    await onPlatform(TargetPlatform.iOS, shaderSupported: true, () async {
      await tester.pumpWidget(
        harness(const MaliGlass(
          variant: MaliGlassVariant.sheet,
          advancedRefraction: true,
          child: Text('sheet'),
        )),
      );
      expect(find.byKey(_advancedKey), findsNothing);
      expect(find.byType(BackdropFilter), findsOneWidget);
    });
  });

  testWidgets(
      'advancedRefraction on an unsupported runtime falls back to Qirsh '
      'frost — no assertion, no blank, no crash', (tester) async {
    await onPlatform(TargetPlatform.iOS, shaderSupported: false, () async {
      await tester.pumpWidget(
        harness(const MaliGlass(
          variant: MaliGlassVariant.navigation,
          advancedRefraction: true,
          child: Text('nav'),
        )),
      );
      expect(tester.takeException(), isNull);
      expect(find.byKey(_advancedKey), findsNothing);
      expect(find.text('nav'), findsOneWidget);
      expect(find.byType(BackdropFilter), findsOneWidget);
    });
  });

  testWidgets('MaliGlassRegion is a passthrough when gated off',
      (tester) async {
    await onPlatform(TargetPlatform.android, shaderSupported: true, () async {
      await tester.pumpWidget(
        harness(const MaliGlassRegion(child: Text('inside'))),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('inside'), findsOneWidget);
    });
  });

  testWidgets(
      'high contrast beats advancedRefraction: opaque surface, no filters',
      (tester) async {
    await onPlatform(TargetPlatform.iOS, shaderSupported: true, () async {
      await tester.pumpWidget(
        harness(
          const MaliGlass(
            variant: MaliGlassVariant.navigation,
            advancedRefraction: true,
            child: Text('nav'),
          ),
          mq: (d) => d.copyWith(highContrast: true),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byKey(_advancedKey), findsNothing);
      expect(find.byType(BackdropFilter), findsNothing);
      expect(find.text('nav'), findsOneWidget);
    });
  });

  testWidgets(
      'reduce-motion with advancedRefraction stays structurally '
      'static', (tester) async {
    debugAdvancedShaderOverride = false;
    addTearDown(() => debugAdvancedShaderOverride = null);
    await tester.pumpWidget(
      harness(
        MaliGlass(
          variant: MaliGlassVariant.pill,
          advancedRefraction: true,
          onTap: () {},
          child: const Text('go'),
        ),
        mq: (d) => d.copyWith(disableAnimations: true),
      ),
    );
    final gesture =
        await tester.startGesture(tester.getCenter(find.text('go')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(AnimatedScale), findsNothing);
    expect(find.byType(AnimatedOpacity), findsNothing);
    await gesture.up();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
