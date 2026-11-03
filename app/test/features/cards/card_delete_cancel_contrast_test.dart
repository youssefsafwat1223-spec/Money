import 'dart:math' as math;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/glass_dialog.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/l10n/app_localizations.dart';

import '../../../tool/visual_parity/card_outcome_surfaces.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'card-cancel-contrast-memory';
  @override
  Future<String?> readStoredKey() async => 'card-cancel-contrast-memory';
}

Future<Map<String, Object>> _snapshot(AppDatabase db) async {
  final tables = await db
      .customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
      .get();
  return {
    for (final table in tables)
      table.read<String>('name'): (await db
              .customSelect(
                  'SELECT * FROM "${table.read<String>('name')}" ORDER BY rowid')
              .get())
          .map((row) => row.data)
          .toList()
  };
}

Future<void> _io(WidgetTester tester) async {
  await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 80)));
  await tester.pump(const Duration(milliseconds: 350));
}

void main() {
  for (final language in ['ar', 'en']) {
    for (final dark in [false, true]) {
      testWidgets('actual Card Delete Cancel contrast $language dark=$dark',
          (tester) async {
        tester.view.physicalSize = const Size(375, 667);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        late AppDatabase db;
        await tester.runAsync(() async {
          final font = FontLoader('Vazirmatn');
          for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
            font.addFont(rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
          }
          await font.load();
          db = await AppDatabase.open(
              executor: NativeDatabase.memory(), keyStore: _Keys());
        });
        final parent = ProviderContainer(
            overrides: [appDatabaseProvider.overrideWithValue(db)]);
        addTearDown(() async {
          final close = closeVisualParityCardOutcome();
          await tester.pumpAndSettle();
          await tester.runAsync(() => close);
          parent.dispose();
          await db.close();
        });
        final parentBefore = await tester.runAsync(() => _snapshot(db));
        const key = 'cardFormDeleting';
        final events = visualParityCardOutcomeEvents();
        Future<bool?>? opening;
        await tester.pumpWidget(UncontrolledProviderScope(
            container: parent,
            child: MaterialApp(
                theme: dark ? AppTheme.dark : AppTheme.light,
                locale: Locale(language),
                supportedLocales: AppL10n.supportedLocales,
                localizationsDelegates: AppL10n.localizationsDelegates,
                builder: (context, child) =>
                    Stack(fit: StackFit.expand, children: [
                      child!,
                      ValueListenableBuilder<Widget?>(
                          valueListenable: visualParityCardOutcomeOverlay,
                          builder: (_, overlay, __) =>
                              overlay ?? const SizedBox.shrink())
                    ]),
                home: Consumer(
                    builder: (context, ref, _) => Scaffold(
                        body: TextButton(
                            onPressed: () {
                              opening = tester.runAsync(() =>
                                  openVisualParityCardOutcome(
                                      context, ref, key));
                            },
                            child: const Text('Open actual card')))))));
        await tester.tap(find.text('Open actual card'));
        expect(await opening, isTrue);
        await tester.pumpAndSettle();
        await _io(tester);
        final formContext = tester.element(find.byType(TextField).first);
        final childDb =
            ProviderScope.containerOf(formContext).read(appDatabaseProvider);
        final childBefore = await tester.runAsync(() => _snapshot(childDb));
        final l10n = AppL10n.of(formContext);
        final ownedNavigator = Navigator.of(formContext);
        final delete = find.widgetWithText(TextButton, l10n.cfDeleteCard);
        await tester.ensureVisible(delete);
        await tester.pumpAndSettle();
        await tester.tap(delete);
        await tester.pumpAndSettle();
        expect(find.byType(GlassAlertDialog), findsOneWidget);
        final cancel = find.widgetWithText(TextButton, l10n.commonCancel);
        final label =
            find.descendant(of: cancel, matching: find.text(l10n.commonCancel));
        final cancelContext = tester.element(cancel);
        final paragraph = tester.renderObject<RenderParagraph>(label);
        final foreground = paragraph.text.style!.color!;
        final background = tester
            .widgetList<Material>(
                find.ancestor(of: label, matching: find.byType(Material)))
            .firstWhere((material) => material.color?.a == 1)
            .color!;
        final painted = Color.alphaBlend(foreground, background);
        final a = painted.computeLuminance();
        final b = background.computeLuminance();
        final contrast = (math.max(a, b) + .05) / (math.min(a, b) + .05);
        debugPrint('Card Cancel paint $language dark=$dark: '
            'foreground=$foreground background=$background contrast=$contrast');
        if (!dark) {
          final actual = tester.widget<TextButton>(cancel);
          final expected = TextButtonTheme.of(cancelContext)
                  .style
                  ?.foregroundColor
                  ?.resolve({}) ??
              actual.defaultStyleOf(cancelContext).foregroundColor!.resolve({});
          expect(foreground, expected,
              reason: 'Light Cancel keeps its exact existing theme/SDK paint');
        }
        expect(cancel.hitTestable(), findsOneWidget);
        expect(Navigator.of(cancelContext), same(ownedNavigator));
        await tester.tap(cancel);
        await tester.pumpAndSettle();
        expect(find.byType(GlassAlertDialog), findsNothing);
        expect(visualParityCardOutcomeEvents()[key] ?? 0, events[key] ?? 0);
        expect(await tester.runAsync(() => _snapshot(childDb)), childBefore);
        final close = closeVisualParityCardOutcome();
        await tester.pumpAndSettle();
        for (var i = 0;
            i < 20 &&
                (visualParityCardOutcomeEvents()['${key}Closed'] ?? 0) ==
                    (events['${key}Closed'] ?? 0);
            i++) {
          await _io(tester);
          await tester.pumpAndSettle();
        }
        await tester.runAsync(() => close);
        expect(visualParityCardOutcomeEvents()['${key}Closed'],
            (events['${key}Closed'] ?? 0) + 1);
        expect(await tester.runAsync(() => _snapshot(db)), parentBefore);
        expect(tester.takeException(), isNull);
        expect(contrast, greaterThanOrEqualTo(4.5),
            reason:
                'Actual Cancel label must be readable on its opaque dialog');
      });
    }
  }
}
