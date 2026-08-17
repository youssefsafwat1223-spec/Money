import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/mali_glass.dart';
import 'package:money_companion/core/theme/widgets/mali_glass_advanced.dart';

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

  group(
      'resolveGlassTier — the decision layer never reaches the package '
      'unsupported', () {
    test('high contrast always wins with opaque', () {
      expect(
        resolveGlassTier(
          advancedRequested: true,
          shaderSupported: true,
          highContrast: true,
          nativeGlassActive: true,
        ),
        GlassTier.opaque,
      );
    });

    test('native wins over advanced when active', () {
      expect(
        resolveGlassTier(
          advancedRequested: true,
          shaderSupported: true,
          highContrast: false,
          nativeGlassActive: true,
        ),
        GlassTier.native,
      );
    });

    test('advanced only when requested AND supported', () {
      expect(
        resolveGlassTier(
          advancedRequested: true,
          shaderSupported: true,
          highContrast: false,
          nativeGlassActive: false,
        ),
        GlassTier.advanced,
      );
      expect(
        resolveGlassTier(
          advancedRequested: true,
          shaderSupported: false,
          highContrast: false,
          nativeGlassActive: false,
        ),
        GlassTier.frost,
      );
      expect(
        resolveGlassTier(
          advancedRequested: false,
          shaderSupported: true,
          highContrast: false,
          nativeGlassActive: false,
        ),
        GlassTier.frost,
      );
    });
  });

  testWidgets(
      'advancedRefraction on an unsupported runtime falls back to Qirsh '
      'frost — no assertion, no blank, no crash', (tester) async {
    debugAdvancedShaderOverride = false;
    addTearDown(() => debugAdvancedShaderOverride = null);
    await tester.pumpWidget(
      harness(const MaliGlass(
        variant: MaliGlassVariant.navigation,
        advancedRefraction: true,
        child: Text('nav'),
      )),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('nav'), findsOneWidget);
    // The Qirsh frost path (BackdropFilter) rendered instead of the package.
    expect(find.byType(BackdropFilter), findsOneWidget);
  });

  testWidgets('MaliGlassRegion is a passthrough when unsupported',
      (tester) async {
    debugAdvancedShaderOverride = false;
    addTearDown(() => debugAdvancedShaderOverride = null);
    await tester.pumpWidget(
      harness(const MaliGlassRegion(child: Text('inside'))),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('inside'), findsOneWidget);
  });

  testWidgets(
      'high contrast beats advancedRefraction: opaque surface, no filters',
      (tester) async {
    debugAdvancedShaderOverride = true;
    addTearDown(() => debugAdvancedShaderOverride = null);
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
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.text('nav'), findsOneWidget);
  });

  testWidgets('reduce-motion with advancedRefraction stays structurally static',
      (tester) async {
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
