import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/repositories/account_repository.dart';
import 'package:money_companion/features/accounts/accounts_screen.dart';

class _AccountRepository implements AccountRepository {
  final createCompleter = Completer<AccountEntity>();
  final createdIds = <String>[];
  var createCalls = 0;
  var failFirstCreate = false;

  @override
  Future<List<AccountEntity>> getAll() async => const [];

  @override
  Future<AccountEntity> create(AccountEntity account) async {
    createCalls += 1;
    createdIds.add(account.id);
    if (failFirstCreate && createCalls == 1) {
      throw Exception('unexpected');
    }
    if (failFirstCreate) return account;
    return createCompleter.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _app(_AccountRepository repository) {
  return ProviderScope(
    overrides: [
      accountRepositoryProvider.overrideWithValue(repository),
      accountsProvider.overrideWith((_) async => const []),
      activeCurrenciesProvider.overrideWith((_) async => const []),
    ],
    child: MaterialApp(
      theme: AppTheme.light,
      home: const Directionality(
        textDirection: TextDirection.rtl,
        child: AccountsScreen(),
      ),
    ),
  );
}

Future<void> _openCreateForm(
  WidgetTester tester,
  _AccountRepository repository,
) async {
  await tester.pumpWidget(_app(repository));
  await tester.pump();
  await tester.tap(find.text('إضافة حساب'));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const ValueKey('account-name-field')),
    'حساب الاختبار',
  );
}

void main() {
  testWidgets('rapid save taps issue one account create request',
      (tester) async {
    final repository = _AccountRepository();
    await _openCreateForm(tester, repository);

    final save = find.byKey(const ValueKey('account-save-button'));
    await tester.tap(save);
    await tester.tap(save, warnIfMissed: false);
    await tester.pump();

    expect(repository.createCalls, 1);
    expect(repository.createdIds.single, isNotEmpty);
    expect(find.byType(CircularProgressIndicator), findsWidgets);

    repository.createCompleter.complete(
      AccountEntity(
        id: repository.createdIds.single,
        name: 'حساب الاختبار',
        currency: 'SAR',
        type: AccountType.bank,
        isDefault: false,
        sortOrder: 0,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      ),
    );
    await tester.pumpAndSettle();
  });

  testWidgets('unexpected failure keeps form values and reuses create id',
      (tester) async {
    final repository = _AccountRepository()..failFirstCreate = true;
    await _openCreateForm(tester, repository);

    final save = find.byKey(const ValueKey('account-save-button'));
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(find.textContaining('حدث خطأ غير متوقع'), findsOneWidget);
    expect(find.text('حساب الاختبار'), findsOneWidget);

    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(repository.createCalls, 2);
    expect(repository.createdIds.toSet(), hasLength(1));
  });
}
