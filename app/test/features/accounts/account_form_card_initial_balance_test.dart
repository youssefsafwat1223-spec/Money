// F-021 (NULL↔0 normalization at the write source) — saving a CARD account
// must preserve its persisted initial balance, not overwrite it with NULL.
//
// QA evidence (demo stack, 2026-08-27): the card branch of the account form
// hard-coded `startingBalanceMoney = null`, so every card save silently
// rewrote a server-seeded 0.00 to local NULL. The sync compare then saw
// NULL ≠ 0 forever — the standing acc-mada conflict.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/catalog/catalog_daos.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/features/accounts/account_form_sheet.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';

  @override
  Future<String?> readStoredKey() async => 'test-key';
}

Future<AppDatabase> _openDb() => AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );

class _Opener extends ConsumerWidget {
  const _Opener(this.account);

  final AccountEntity account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          onPressed: () => showAccountForm(context, ref, account: account),
          child: const Text('افتح'),
        ),
      ),
    );
  }
}

Future<void> _waitForSave(WidgetTester tester) async {
  for (var i = 0;
      i < 20 &&
          find
              .byKey(const ValueKey('account-save-button'))
              .evaluate()
              .isNotEmpty;
      i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'F-021: saving a card account preserves its persisted zero initial '
      'balance instead of rewriting it to NULL', (tester) async {
    final db = (await tester.runAsync(_openDb))!;
    const now = '2026-08-25T00:00:00.000Z';

    try {
      await tester.runAsync(() async {
        await db.customStatement('DELETE FROM accounts;');
        // The server-seeded shape: a card whose starting balance is 0.00.
        await db.customStatement('''
          INSERT INTO accounts(id,name,currency,type,initial_balance,initial_balance_minor,
            current_balance,current_balance_minor,is_default,sort_order,created_at,updated_at)
          VALUES('card-zero','بطاقة مدى','SAR','card',0.0,0,
            -1240.5,-124050,0,1,'$now','$now');
        ''');
      });

      final repository = DriftAccountRepository(db);
      final account =
          await tester.runAsync(() => repository.getById('card-zero'));
      expect(account!.initialBalanceMoney!.minorUnits, 0);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            accountRepositoryProvider.overrideWithValue(repository),
            accountHasTransactionsProvider.overrideWith((ref, id) async => false),
            accountsProvider.overrideWith((_) async => const []),
            activeCurrenciesProvider.overrideWith((_) async => [
              RemoteCurrency(
                code: 'SAR',
                nameAr: 'ريال',
                nameEn: 'SAR',
                symbol: 'ر.س',
                decimalPlaces: 2,
                countryCodes: const [],
                isActive: true,
                isDeleted: false,
                updatedAt: DateTime.utc(2026),
              ),
            ]),
          ],
          child: MaterialApp(theme: AppTheme.light, home: _Opener(account)),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('افتح'));
      await tester.pumpAndSettle();

      // Rename first so a persisted change PROVES the save executed — the
      // assertion below cannot pass vacuously on a save that never ran.
      await tester.enterText(
          find.byKey(const ValueKey('account-name-field')), 'بطاقة معدلة');
      // Invoke the save handler directly: in this harness the tall card form
      // leaves the button's hit-point outside the sheet, and tap mechanics are
      // not what this regression is about.
      tester
          .widget<FilledButton>(
              find.byKey(const ValueKey('account-save-button')))
          .onPressed!();
      await tester.pump();
      await _waitForSave(tester);

      final persisted = await tester.runAsync(() => db.customSelect('''
        SELECT name, initial_balance_minor, current_balance_minor
        FROM accounts WHERE id='card-zero';
      ''').getSingle());
      expect(persisted!.read<String>('name'), 'بطاقة معدلة',
          reason: 'the save must actually have executed');
      expect(persisted.read<int?>('initial_balance_minor'), 0,
          reason: 'non-vacuity: the pre-fix card branch forced '
              'startingBalanceMoney = null, so the save wrote NULL here');
      expect(persisted.read<int?>('current_balance_minor'), -124050,
          reason: 'the running balance must survive the save untouched');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.runAsync(db.close);
    }
  });
}
