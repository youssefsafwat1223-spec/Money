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

List<RemoteCurrency> _currencies() => [
      for (final code in const ['KWD', 'USD'])
        RemoteCurrency(
          code: code,
          nameAr: code,
          nameEn: code,
          symbol: code,
          decimalPlaces: code == 'KWD' ? 3 : 2,
          countryCodes: const [],
          isActive: true,
          isDeleted: false,
          updatedAt: DateTime.utc(2026),
        ),
    ];

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

Future<void> _openAccountForm(
  WidgetTester tester, {
  required AccountEntity account,
  required DriftAccountRepository repository,
  required Future<bool> Function() hasTransactions,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        accountRepositoryProvider.overrideWithValue(repository),
        accountHasTransactionsProvider.overrideWith(
          (ref, accountId) => hasTransactions(),
        ),
        accountsProvider.overrideWith((_) async => const []),
        activeCurrenciesProvider.overrideWith((_) async => _currencies()),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        home: _Opener(account),
      ),
    ),
  );
  await tester.pump();
  await tester.tap(find.text('افتح'));
  await tester.pumpAndSettle();
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

DropdownButtonFormField<String> _currencyField(WidgetTester tester) =>
    tester.widget<DropdownButtonFormField<String>>(
      find.byKey(const ValueKey('account-currency-field')),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'saving an untouched existing account preserves exact current_balance_minor',
      (tester) async {
    final db = (await tester.runAsync(_openDb))!;
    const currentMinor = 9007199254740993; // > 2^53
    const now = '2026-08-25T00:00:00.000Z';

    try {
      await tester.runAsync(() async {
        await db.customStatement('DELETE FROM accounts;');
        await db.customStatement('''
          INSERT INTO accounts(id,name,currency,type,initial_balance,initial_balance_minor,
            current_balance,current_balance_minor,is_default,sort_order,created_at,updated_at)
          VALUES('account-edit','KWD account','KWD','bank',12.345,12345,
            1.0,$currentMinor,1,0,'$now','$now');
        ''');
      });

      final repository = DriftAccountRepository(db);
      final account =
          await tester.runAsync(() => repository.getById('account-edit'));
      expect(account, isNotNull);
      expect(account!.currentBalanceMoney!.minorUnits, currentMinor);
      expect(account.currentBalanceMoney!.currency, 'KWD');

      await _openAccountForm(
        tester,
        account: account,
        repository: repository,
        hasTransactions: () async => false,
      );
      expect(_currencyField(tester).onChanged, isNull,
          reason: 'a non-zero current balance must lock currency editing');
      await tester.tap(find.byKey(const ValueKey('account-save-button')));
      await _waitForSave(tester);

      final persisted = await tester.runAsync(() => db.customSelect('''
        SELECT current_balance,current_balance_minor
        FROM accounts WHERE id='account-edit';
      ''').getSingle());
      expect(persisted!.read<int?>('current_balance_minor'), currentMinor,
          reason:
              'non-vacuity: the pre-fix form omitted currentBalanceMoney, so '
              'DriftAccountRepository.update wrote NULL to both balance columns');
      expect(persisted.read<double?>('current_balance'), isNotNull,
          reason: 'the compatibility REAL shadow must be dual-written too');
      final currency = await tester.runAsync(() => db
          .customSelect(
            "SELECT currency FROM accounts WHERE id='account-edit';",
          )
          .getSingle());
      expect(currency!.read<String>('currency'), 'KWD',
          reason:
              'the carried KWD Money must never be persisted as another currency');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.runAsync(db.close);
    }
  });

  testWidgets('a transaction-only account keeps the currency selector locked',
      (tester) async {
    final db = (await tester.runAsync(_openDb))!;
    const now = '2026-08-25T00:00:00.000Z';
    try {
      await tester.runAsync(() async {
        await db.customStatement('DELETE FROM accounts;');
        await db.customStatement('''
          INSERT INTO accounts(id,name,currency,type,initial_balance,initial_balance_minor,
            current_balance,current_balance_minor,is_default,sort_order,created_at,updated_at)
          VALUES('transaction-account','Used KWD','KWD','bank',0,0,0,0,1,0,
            '$now','$now');
        ''');
      });
      final repository = DriftAccountRepository(db);
      final account = await tester
          .runAsync(() => repository.getById('transaction-account'));

      await _openAccountForm(
        tester,
        account: account!,
        repository: repository,
        hasTransactions: () async => true,
      );

      expect(_currencyField(tester).onChanged, isNull,
          reason: 'ledger history alone makes the account in use');
      expect(find.text('لا يمكن تغيير عملة حساب مستخدم'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.runAsync(db.close);
    }
  });

  testWidgets(
      'save re-check rejects a currency change when the account becomes in use',
      (tester) async {
    final db = (await tester.runAsync(_openDb))!;
    const now = '2026-08-25T00:00:00.000Z';
    var usageChecks = 0;
    try {
      await tester.runAsync(() async {
        await db.customStatement('DELETE FROM accounts;');
        await db.customStatement('''
          INSERT INTO accounts(id,name,currency,type,initial_balance,initial_balance_minor,
            current_balance,current_balance_minor,is_default,sort_order,created_at,updated_at)
          VALUES('race-account','Empty KWD','KWD','bank',0,0,0,0,1,0,
            '$now','$now');
        ''');
      });
      final repository = DriftAccountRepository(db);
      final account =
          await tester.runAsync(() => repository.getById('race-account'));

      await _openAccountForm(
        tester,
        account: account!,
        repository: repository,
        hasTransactions: () async => usageChecks++ > 0,
      );
      expect(_currencyField(tester).onChanged, isNotNull);
      await tester.tap(find.byKey(const ValueKey('account-currency-field')));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('USD —').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('account-save-button')));
      await tester.pumpAndSettle();

      expect(
        find.text('لا يمكن تغيير عملة حساب يحتوي على رصيد أو عمليات.'),
        findsOneWidget,
      );
      final persisted = await tester.runAsync(() => db.customSelect('''
        SELECT currency,current_balance_minor
        FROM accounts WHERE id='race-account';
      ''').getSingle());
      expect(persisted!.read<String>('currency'), 'KWD');
      expect(persisted.read<int?>('current_balance_minor'), 0,
          reason: 'the rejected save must not write a wrong-scale row');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.runAsync(db.close);
    }
  });

  testWidgets('a genuinely empty existing account can change currency',
      (tester) async {
    final db = (await tester.runAsync(_openDb))!;
    const now = '2026-08-25T00:00:00.000Z';
    try {
      await tester.runAsync(() async {
        await db.customStatement('DELETE FROM accounts;');
        await db.customStatement('''
          INSERT INTO accounts(id,name,currency,type,initial_balance,initial_balance_minor,
            current_balance,current_balance_minor,is_default,sort_order,created_at,updated_at)
          VALUES('empty-account','Empty KWD','KWD','bank',0,0,0,0,1,0,
            '$now','$now');
        ''');
      });
      final repository = DriftAccountRepository(db);
      final account =
          await tester.runAsync(() => repository.getById('empty-account'));

      await _openAccountForm(
        tester,
        account: account!,
        repository: repository,
        hasTransactions: () async => false,
      );
      expect(_currencyField(tester).onChanged, isNotNull);
      await tester.tap(find.byKey(const ValueKey('account-currency-field')));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('USD —').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('account-save-button')));
      await _waitForSave(tester);

      final persisted =
          await tester.runAsync(() => repository.getById('empty-account'));
      expect(persisted!.currency, 'USD');
      expect(persisted.currentBalanceMoney!.minorUnits, 0);
      expect(persisted.currentBalanceMoney!.currency, 'USD',
          reason: 'zero Money is recreated under USD, never carried from KWD');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.runAsync(db.close);
    }
  });
}
