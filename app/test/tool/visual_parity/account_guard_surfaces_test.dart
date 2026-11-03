import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/core/theme/widgets/glass_dropdown_field.dart';
import 'package:money_companion/core/theme/widgets/glass_dialog.dart';
import 'package:money_companion/features/accounts/account_form_sheet.dart';
import 'package:money_companion/l10n/app_localizations.dart';

import '../../../tool/visual_parity/account_guard_surfaces.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'account-guard-test';
  @override
  Future<String?> readStoredKey() async => 'account-guard-test';
}

Future<Map<String, Object>> _snapshot(AppDatabase db) async {
  final tables = await db
      .customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
      .get();
  return {
    for (final row in tables)
      row.read<String>('name'): (await db
              .customSelect(
                  'SELECT * FROM "${row.read<String>('name')}" ORDER BY rowid')
              .get())
          .map((value) => value.data)
          .toList(),
  };
}

void main() {
  late AppDatabase db;
  setUp(() async {
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(),
        keyStore: _Keys(),
        initialLanguage: 'en');
  });
  tearDown(() async => db.close());

  for (final key in visualParityAccountGuardKeys) {
    for (final language in ['ar', 'en']) {
      testWidgets(
          '$key $language real public account guard leaves both databases unchanged',
          (tester) async {
        tester.view.physicalSize = const Size(375, 667);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.runAsync(() async {
          final font = FontLoader('Vazirmatn');
          for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
            font.addFont(rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
          }
          await font.load();
        });
        final container = ProviderContainer(
            overrides: [appDatabaseProvider.overrideWithValue(db)]);
        addTearDown(container.dispose);
        final parentRepository = container.read(accountRepositoryProvider);
        final parentBefore = await _snapshot(db);
        final forbidden = visualParityAccountGuardEvents()[
                'accountGuardForbiddenDeletionOperation'] ??
            0;
        final closed = visualParityAccountGuardEvents()['${key}Closed'] ?? 0;
        Future<bool>? opening;
        await tester.pumpWidget(UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
                theme: language == 'ar' ? AppTheme.dark : AppTheme.light,
                locale: Locale(language),
                supportedLocales: AppL10n.supportedLocales,
                localizationsDelegates: AppL10n.localizationsDelegates,
                home: Consumer(
                    builder: (context, ref, _) => Scaffold(
                            body: TextButton(
                          onPressed: () => opening = tester
                              .runAsync(() => openVisualParityAccountGuard(
                                  context, ref, key))
                              .then((value) => value!),
                          child: const Text('Open account guard'),
                        ))))));
        await tester.tap(find.text('Open account guard'));
        expect(await opening!, isTrue);
        await tester.pumpAndSettle();
        final form = find.byType(AccountFormPanel);
        expect(form, findsOneWidget);
        final element = tester.element(form);
        final child = ProviderScope.containerOf(element);
        final childDb = child.read(appDatabaseProvider);
        expect(identical(childDb, db), isFalse);
        final childBefore = await _snapshot(childDb);
        final accounts = await child.read(accountRepositoryProvider).getAll();
        expect(accounts, hasLength(1));
        expect(accounts.single.initialBalanceMoney!.minorUnits, 0);
        expect(accounts.single.currentBalanceMoney!.minorUnits, 0);
        final l10n = AppL10n.of(element);
        final field = find.byKey(const ValueKey('account-currency-field'));
        await tester.ensureVisible(field);
        await tester.pumpAndSettle();
        final dropdown = tester.widget<GlassDropdownField<String>>(field);
        if (key == 'accountCurrencyLinked') {
          expect(
              await child.read(
                  accountHasTransactionsProvider(accounts.single.id).future),
              isTrue);
          final ledger = await child
              .read(transactionRepositoryProvider)
              .getRecent(accountId: accounts.single.id);
          expect(ledger, hasLength(1));
          expect(ledger.single.amountMoney.minorUnits, 12345);
          expect(ledger.single.currency, 'KWD');
          expect(dropdown.onChanged, isNull);
          expect(find.text(l10n.afCurrencyLockedShort), findsOneWidget);
        } else if (key.contains('Usage')) {
          final usage =
              child.read(accountHasTransactionsProvider(accounts.single.id));
          expect(key.endsWith('Loading') ? usage.isLoading : usage.hasError,
              isTrue);
          expect(dropdown.onChanged, isNull);
          expect(find.text(l10n.afCurrencyLockedShort), findsOneWidget);
          expect(find.textContaining('private_account_usage_failure'),
              findsNothing);
          // Attempting the disabled real control cannot open a currency picker.
          await tester.tap(field);
          await tester.pump();
          expect(find.byType(DropdownMenuItem<String>), findsNothing);
        } else {
          expect(
              await child.read(
                  accountHasTransactionsProvider(accounts.single.id).future),
              isFalse);
          expect(dropdown.onChanged, isNotNull);
        }
        if (key == 'accountCannotDeleteLast') {
          final originalEntity = tester.widget<AccountFormPanel>(form).account!;
          expect(originalEntity.isDefault, isFalse,
              reason: 'Actual original nondefault snapshot');
          expect(accounts.single.isDefault, isTrue,
              reason: 'Actual repository promoted successor during setup');
          final delete = find.widgetWithText(TextButton, l10n.afDeleteAccount);
          await tester.ensureVisible(delete);
          await tester.pumpAndSettle();
          await tester.tap(delete);
          await tester.pump(const Duration(milliseconds: 700));
          expect(find.text(l10n.afCannotDeleteLast), findsOneWidget);
          expect(find.byType(GlassAlertDialog), findsNothing);
          expect(find.byType(AccountFormPanel), findsOneWidget);
          await tester.pump(const Duration(seconds: 4));
        }
        if (key == 'accountSoleDefault') {
          expect(accounts.single.isDefault, isTrue);
          expect(find.widgetWithText(TextButton, l10n.afDeleteAccount),
              findsNothing);
        }
        expect(await _snapshot(childDb), childBefore);
        expect(await _snapshot(db), parentBefore);
        expect(
            visualParityAccountGuardEvents()[
                    'accountGuardForbiddenDeletionOperation'] ??
                0,
            forbidden);
        expect(
            identical(
                container.read(accountRepositoryProvider), parentRepository),
            isTrue);
        expect(tester.takeException(), isNull);
        Navigator.of(element).pop();
        await tester.pumpAndSettle();
        await tester.runAsync(
            () async => Future<void>.delayed(const Duration(milliseconds: 80)));
        await tester.pump();
        expect(visualParityAccountGuardEvents()['${key}Closed'], closed + 1);
        expect(find.text('Open account guard'), findsOneWidget);
        expect(await _snapshot(db), parentBefore);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets(
      'unknown account guard key cannot access database or create scope',
      (tester) async {
    var handled = true;
    await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
            home: Consumer(
                builder: (context, ref, _) => TextButton(
                    onPressed: () async {
                      handled = await openVisualParityAccountGuard(
                          context, ref, 'unrelated');
                    },
                    child: const Text('Unknown'))))));
    await tester.tap(find.text('Unknown'));
    await tester.pump();
    expect(handled, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('file parent rejected before child creation or any action',
      (tester) async {
    final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('qirsh-account-guard-')))!;
    final disk = (await tester.runAsync(() => AppDatabase.open(
        executor: NativeDatabase(File('${directory.path}/guard.sqlite')),
        keyStore: _Keys(),
        initialLanguage: 'en')))!;
    addTearDown(() async {
      await disk.close();
      await directory.delete(recursive: true);
    });
    final before = await tester.runAsync(() => _snapshot(disk));
    final events = visualParityAccountGuardEvents();
    Object? rejected;
    await tester.pumpWidget(ProviderScope(
        overrides: [appDatabaseProvider.overrideWithValue(disk)],
        child: MaterialApp(
            home: Consumer(
                builder: (context, ref, _) => TextButton(
                    onPressed: () async {
                      try {
                        await openVisualParityAccountGuard(
                            context, ref, 'accountCannotDeleteLast');
                      } catch (error) {
                        rejected = error;
                      }
                    },
                    child: const Text('Guard'))))));
    await tester.tap(find.text('Guard'));
    await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pump();
    expect(rejected, isA<StateError>());
    expect(rejected.toString(), contains('requires_memory_parent'));
    expect(find.byType(AccountFormPanel), findsNothing);
    expect(await tester.runAsync(() => _snapshot(disk)), before);
    expect(visualParityAccountGuardEvents(), events);
    expect(tester.takeException(), isNull);
  });
}
