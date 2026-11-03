import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_colors.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/glass_dialog.dart';
import 'package:money_companion/l10n/app_localizations.dart';

Color _paint(WidgetTester tester, String label) =>
    tester.renderObject<RenderParagraph>(find.text(label)).text.style!.color!;
Color _background(WidgetTester tester, String label) => tester
    .widgetList<Material>(
        find.ancestor(of: find.text(label), matching: find.byType(Material)))
    .firstWhere((material) => material.color?.a == 1)
    .color!;
double _contrast(Color foreground, Color background) {
  final a = Color.alphaBlend(foreground, background).computeLuminance();
  final b = background.computeLuminance();
  return (math.max(a, b) + .05) / (math.min(a, b) + .05);
}

Future<void> _font(WidgetTester tester) async {
  await tester.runAsync(() async {
    final font = FontLoader('Vazirmatn');
    for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      font.addFont(rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
    }
    await font.load();
  });
}

void main() {
  for (final language in ['ar', 'en']) {
    for (final dark in [false, true]) {
      testWidgets('default dialog actions actual paint $language dark=$dark',
          (tester) async {
        tester.view.physicalSize = const Size(375, 667);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await _font(tester);
        late BuildContext host;
        var retryCalls = 0, dangerCalls = 0, filledCalls = 0, outsideCalls = 0;
        bool? result;
        late List<Widget> actions;
        await tester.pumpWidget(MaterialApp(
            theme: dark ? AppTheme.dark : AppTheme.light,
            locale: Locale(language),
            supportedLocales: AppL10n.supportedLocales,
            localizationsDelegates: AppL10n.localizationsDelegates,
            home: Builder(builder: (context) {
              host = context;
              return Scaffold(
                  body: TextButton(
                      onPressed: () {
                        outsideCalls++;
                      },
                      child: const Text('Outside')));
            })));
        final navigator = Navigator.of(host);
        final outsideBefore = _paint(tester, 'Outside');
        final c = Theme.of(host).extension<AppColors>()!;
        final l10n = AppL10n.of(host);
        final cancel = l10n.commonCancel, retry = l10n.startRetry;
        await tester.runAsync(() async {
          // The returned result is observed without awaiting until the actual
          // public Cancel dismisses this owned route.
          showDialog<bool>(
              context: host,
              builder: (dialogContext) {
                actions = [
                  TextButton(
                      onPressed: () => Navigator.of(dialogContext).pop(false),
                      child: Text(cancel)),
                  TextButton(
                      onPressed: () {
                        retryCalls++;
                      },
                      child: Text(retry)),
                  TextButton.icon(
                      onPressed: () {
                        dangerCalls++;
                      },
                      style: TextButton.styleFrom(foregroundColor: c.danger),
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Danger')),
                  TextButton(
                      onPressed: () {
                        dangerCalls++;
                      },
                      child: Text('Child danger',
                          style: TextStyle(color: c.danger))),
                  const TextButton(onPressed: null, child: Text('Disabled')),
                  FilledButton(
                      onPressed: () {
                        filledCalls++;
                      },
                      child: const Text('Primary')),
                ];
                return GlassAlertDialog(
                    title: const Text('QA dialog'),
                    content: const Text('Actual action paint'),
                    actions: actions);
              }).then((value) {
            result = value;
          });
        });
        await tester.pumpAndSettle();
        final dialog =
            tester.widget<GlassAlertDialog>(find.byType(GlassAlertDialog));
        expect(dialog.actions, same(actions));
        expect(
            Navigator.of(tester.element(find.text(cancel))), same(navigator));
        expect(_paint(tester, 'Outside'), outsideBefore);
        expect(_paint(tester, 'Danger'), c.danger);
        expect(
            IconTheme.of(tester.element(find.byIcon(Icons.delete_outline)))
                .color,
            c.danger);
        expect(_paint(tester, 'Child danger'), c.danger);
        final disabled = tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Disabled'));
        final disabledContext =
            tester.element(find.widgetWithText(TextButton, 'Disabled'));
        final disabledExpected = disabled
            .defaultStyleOf(disabledContext)
            .foregroundColor!
            .resolve({WidgetState.disabled});
        expect(_paint(tester, 'Disabled'), disabledExpected);
        expect(disabled.onPressed, isNull);
        final primary = tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Primary'));
        final primaryContext =
            tester.element(find.widgetWithText(FilledButton, 'Primary'));
        expect(
            _paint(tester, 'Primary'),
            primary
                .defaultStyleOf(primaryContext)
                .foregroundColor!
                .resolve({}));
        final neutralPaint = _paint(tester, cancel),
            retryPaint = _paint(tester, retry);
        final background = _background(tester, cancel);
        if (!dark) {
          final button = tester
              .widget<TextButton>(find.widgetWithText(TextButton, cancel));
          final context =
              tester.element(find.widgetWithText(TextButton, cancel));
          expect(neutralPaint,
              button.defaultStyleOf(context).foregroundColor!.resolve({}));
          expect(TextButtonTheme.of(context).style,
              Theme.of(host).textButtonTheme.style);
        }
        await tester.tap(find.text(retry));
        await tester.pump();
        expect(retryCalls, 1);
        expect(dangerCalls, 0);
        expect(filledCalls, 0);
        expect(outsideCalls, 0);
        await tester.tap(find.text(cancel));
        await tester.pumpAndSettle();
        await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
        expect(result, isFalse);
        expect(find.byType(GlassAlertDialog), findsNothing);
        expect(_paint(tester, 'Outside'), outsideBefore);
        debugPrint(
            'Dialog neutral $language dark=$dark foreground=$neutralPaint background=$background ratio=${_contrast(neutralPaint, background)}');
        expect(_contrast(neutralPaint, background), greaterThanOrEqualTo(4.5));
        expect(_contrast(retryPaint, background), greaterThanOrEqualTo(4.5));
        expect(tester.takeException(), isNull);
      });
    }
  }
  for (final dark in [false, true]) {
    testWidgets('dialog preserves inherited button overrides dark=$dark',
        (tester) async {
      const disabled = Color(0xFF778899), enabled = Color(0xFFCCEEFF);
      final inherited = ButtonStyle(
          foregroundColor: WidgetStateProperty.resolveWith((states) =>
              states.contains(WidgetState.disabled) ? disabled : enabled),
          padding: const WidgetStatePropertyAll(EdgeInsets.all(19)));
      await tester.pumpWidget(MaterialApp(
          theme: dark ? AppTheme.dark : AppTheme.light,
          home: TextButtonTheme(
              data: TextButtonThemeData(style: inherited),
              child: const Scaffold(
                  body: GlassAlertDialog(content: Text('Overrides'), actions: [
                TextButton(onPressed: _noop, child: Text('Custom')),
                TextButton(onPressed: null, child: Text('Custom disabled')),
              ])))));
      await tester.pumpAndSettle();
      expect(_paint(tester, 'Custom'), enabled);
      expect(_paint(tester, 'Custom disabled'), disabled);
      final context = tester.element(find.widgetWithText(TextButton, 'Custom'));
      expect(TextButtonTheme.of(context).style!.padding!.resolve({}),
          const EdgeInsets.all(19));
      expect(tester.takeException(), isNull);
    });
  }
  for (final interaction in [
    WidgetState.hovered,
    WidgetState.focused,
    WidgetState.pressed
  ]) {
    testWidgets('dark neutral action stays readable during $interaction',
        (tester) async {
      final states = WidgetStatesController({interaction});
      addTearDown(states.dispose);
      await tester.pumpWidget(MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
              body: GlassAlertDialog(content: const Text('States'), actions: [
            TextButton(
                statesController: states,
                onPressed: _noop,
                child: const Text('State action')),
          ]))));
      await tester.pumpAndSettle();
      expect(_paint(tester, 'State action'), AppColors.dark.textPrimary);
      final button = tester.widget<TextButton>(find.byType(TextButton));
      expect(button.statesController, same(states));
      expect(states.value, contains(interaction));
      expect(tester.takeException(), isNull);
    });
  }
}

void _noop() {}
