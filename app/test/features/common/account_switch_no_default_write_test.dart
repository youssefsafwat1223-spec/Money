// F-020 regression — viewing/selecting an account must NOT mutate the
// persistent default account.
//
// QA evidence (demo-docker, 2026-08-26/27): every account switch in the Home /
// Transactions pickers called `repo.setDefault()`, which enqueues a
// `set_default_account` server command. Merely browsing accounts produced
// server revision churn (rev 19→36 / 23→37 / 11→15 on the demo stack), stale
// whole-row outbox snapshots, and repeated sync conflicts. Intended semantics:
// active/viewed account = temporary UI/filter state (`activeAccountIdProvider`)
// · default account = persistent user preference changed ONLY by an explicit
// "make default" action (account_form_sheet).
//
// This test drives the REAL account picker sheet and fails if selecting an
// account performs ANY repository mutation.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/repositories/account_repository.dart';
import 'package:money_companion/features/common/account_range_controls.dart';

AccountEntity _account(String id, String name, {bool isDefault = false}) {
  final t = DateTime.utc(2026, 1, 1);
  return AccountEntity(
    id: id,
    name: name,
    currency: 'SAR',
    type: AccountType.bank,
    isDefault: isDefault,
    sortOrder: isDefault ? 0 : 1,
    createdAt: t,
    updatedAt: t,
  );
}

class _RecordingAccountRepository implements AccountRepository {
  final accounts = <AccountEntity>[
    _account('acc-default', 'الحساب الافتراضي', isDefault: true),
    _account('acc-other', 'حساب آخر'),
  ];
  final setDefaultCalls = <String>[];

  @override
  Future<List<AccountEntity>> getAll() async => accounts;

  @override
  Future<void> setDefault(String id) async => setDefaultCalls.add(id);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
      'F-020: picking an account to VIEW sets the active account only — '
      'no setDefault / no repository mutation', (tester) async {
    final repository = _RecordingAccountRepository();
    final container = ProviderContainer(overrides: [
      accountRepositoryProvider.overrideWithValue(repository),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light,
          home: const Directionality(
            textDirection: TextDirection.rtl,
            child: Scaffold(body: AccountRangeControls(showRange: false)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Open the picker (chip shows the default account) and choose the OTHER
    // account — the browse gesture, not an explicit make-default action.
    await tester.tap(find.textContaining('الحساب الافتراضي'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('حساب آخر'));
    await tester.pumpAndSettle();

    expect(container.read(activeAccountIdProvider), 'acc-other',
        reason: 'viewing switches the ACTIVE account (UI state)');
    expect(repository.setDefaultCalls, isEmpty,
        reason: 'F-020: browsing must not rewrite the persistent default '
            '(no setDefault, no outbox command, no server write)');
  });
}
