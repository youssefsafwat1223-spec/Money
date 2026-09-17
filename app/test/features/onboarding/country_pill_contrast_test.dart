import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/onboarding/setup_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

/// The country selector on the mandatory first-run setup step shipped as solid
/// white pills carrying white labels. Measured on the device capture, an
/// unselected pill was rgb(255,255,255) against an rgb(8,26,116) page: a new
/// user could read exactly one country — the one already selected — in BOTH
/// languages.
///
/// The reason it survived is the point of this test. It was a `ChoiceChip`, and
/// Material's chip paints its own surface from the ambient theme UNDERNEATH
/// anything the widget sets. On a screen that paints its own navy over the
/// app's LIGHT theme, that surface is white. Three fixes were tried — per-chip
/// `backgroundColor`, per-chip `color`, an ancestor `ChipTheme` — and all three
/// "passed" a widget test that read the chip's `Ink` decoration and reported
/// `white @ 10%`. All three still landed white on the device. Reading the
/// property proved nothing, because the property was never what painted.
///
/// So the rule kept here is structural: this screen owns its pill. Whether the
/// pixels are right is settled on the device, where the defect was visible —
/// `~/.qirsh-qa/visual-closure-2026-09-17/` with `tool/png_sample.py`.
void main() {
  testWidgets('the country selector does not use a themed Material chip',
      (tester) async {
    final onError = FlutterError.onError;
    FlutterError.onError = (_) {};
    addTearDown(() => FlutterError.onError = onError);

    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('en'),
        supportedLocales: AppL10n.supportedLocales,
        localizationsDelegates: const [
          ...AppL10n.localizationsDelegates,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: const OnboardingSetupScreen(),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 200));
    tester.takeException();

    expect(find.byType(ChoiceChip), findsNothing,
        reason: 'a Material chip paints the ambient theme surface inside its '
            'own shape, under everything the widget sets — on this navy screen '
            'that is a white pill, and the labels are white');

    final pills = find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == '_CountryPill');
    expect(pills, findsWidgets,
        reason: 'the country selector must still render its choices');

    // Every pill paints through a transparent Material, so nothing under it
    // contributes a surface colour of its own.
    for (final material in tester.widgetList<Material>(find.descendant(
        of: pills.first, matching: find.byType(Material)))) {
      expect(material.type, MaterialType.transparency,
          reason: 'an opaque Material inside the pill would paint over the '
              'decoration again, which is the whole defect');
    }

    // And the fill it does paint must be dark enough to carry white text.
    final ink = tester.widget<Ink>(
        find.descendant(of: pills.at(1), matching: find.byType(Ink)));
    final decoration = ink.decoration as ShapeDecoration;
    expect(decoration.color!.a, lessThan(0.5),
        reason: 'the unselected fill must stay translucent over the navy page; '
            'white copy sits on it');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
