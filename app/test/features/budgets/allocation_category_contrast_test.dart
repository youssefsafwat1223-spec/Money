import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/i18n/locale_provider.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/app_colors.dart';
import 'package:money_companion/core/utils/category_glyph.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/features/budgets/allocate_income_sheet.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'allocation-contrast-memory';
  @override
  Future<String?> readStoredKey() async => 'allocation-contrast-memory';
}

void main() {
  for (final language in ['ar', 'en']) {
    for (final dark in [false, true]) {
      testWidgets(
          'actual eight allocation category glyphs readable $language dark=$dark',
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
        addTearDown(db.close);
        final container = ProviderContainer(overrides: [
          appDatabaseProvider.overrideWithValue(db),
          localeProvider.overrideWithValue(Locale(language)),
        ]);
        addTearDown(container.dispose);
        await tester.pumpWidget(UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
                theme: dark ? AppTheme.dark : AppTheme.light,
                locale: Locale(language),
                supportedLocales: AppL10n.supportedLocales,
                localizationsDelegates: AppL10n.localizationsDelegates,
                home: Builder(
                    builder: (context) => Scaffold(
                        body: TextButton(
                            onPressed: () => AllocateIncomeSheet.show(context),
                            child: const Text('Open allocation')))))));
        await tester.tap(find.text('Open allocation'));
        await tester.pumpAndSettle();
        final glyphs = find.byType(CategoryGlyph);
        expect(glyphs, findsNWidgets(8));
        final failures = <String>[];
        for (var i = 0; i < 8; i++) {
          final glyph = tester.widget<CategoryGlyph>(glyphs.at(i));
          final box = find.ancestor(
              of: glyphs.at(i),
              matching: find.byWidgetPredicate((w) =>
                  w is Container &&
                  w.constraints?.maxWidth == 36 &&
                  w.constraints?.maxHeight == 36));
          expect(box, findsOneWidget);
          final decoration =
              tester.widget<Container>(box).decoration! as BoxDecoration;
          final colors =
              Theme.of(tester.element(glyphs.at(i))).extension<AppColors>()!;
          final background =
              Color.alphaBlend(decoration.color!, colors.surface);
          final ink = Color.alphaBlend(glyph.color!, background);
          final a = ink.computeLuminance();
          final b = background.computeLuminance();
          final contrast = ((a > b ? a : b) + .05) / ((a > b ? b : a) + .05);
          if (contrast < 3) failures.add('${glyph.name}:$contrast');
        }
        expect(failures, isEmpty,
            reason:
                'Actual rendered tile/icon colors need 3:1 non-text contrast');
        final context = tester.element(find.byType(TextField).first);
        final l10n = AppL10n.of(context);
        await tester.enterText(find.byType(TextField).first, '1000');
        tester.testTextInput.hide();
        await tester.pumpAndSettle();
        await tester.tap(find.text(l10n.aiSuggestSplit));
        await tester.pumpAndSettle();
        final texts = tester
            .widgetList<TextField>(find.byType(TextField))
            .map((w) => w.controller!.text)
            .toList();
        expect(texts.first, '1000');
        expect(texts[1], '150');
        expect(texts.last, '200');
        expect(
            await tester.runAsync(
                () => container.read(budgetRepositoryProvider).getAll()),
            isEmpty);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
