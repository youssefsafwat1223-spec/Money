import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:money_companion/app.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/privacy/data_wipe_service.dart';
import 'package:money_companion/core/security/secure_storage_options.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/startup/bootstrap_runner.dart';
import 'package:money_companion/core/theme/theme_mode_controller.dart';
import 'package:money_companion/core/utils/install_id.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/main.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

const _qaEmail = String.fromEnvironment('QA_EMAIL');
const _qaPassword = String.fromEnvironment('QA_PASSWORD');
const _qaCommit = String.fromEnvironment('QA_GIT_COMMIT');
const _ownerKey = 'local_data_owner_uid';
const _staleOwner = 'qa-stale-owner-before-reinstall';
const _accountId = 'qa-system-restart-account';
const _transactionId = 'qa-system-restart-transaction';
const _goalId = 'qa-system-restart-goal';
const _budgetId = 'qa-system-restart-budget';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<String> readPhase() async {
    final documents = await getApplicationDocumentsDirectory();
    return File(p.join(documents.path, 'qa_system_restart_phase.txt'))
        .readAsStringSync()
        .trim();
  }

  Future<int> count(AppDatabase db, String table, [String? predicate]) async {
    final row = await db
        .customSelect(
          'SELECT COUNT(*) AS c FROM $table'
          '${predicate == null ? '' : ' WHERE $predicate'};',
        )
        .getSingle();
    return row.read<int>('c');
  }

  Future<void> reportSnapshot(String phase, AppDatabase db) async {
    final support = await getApplicationSupportDirectory();
    final file = File(p.join(support.path, 'money_companion.sqlite'));
    final owner = await AppSession.instance.readLocalDataOwnerUid();
    final authUid = supabase.Supabase.instance.client.auth.currentUser?.id;
    final installId = await InstallId.get();
    final settings = await db
        .customSelect('SELECT language FROM user_settings LIMIT 1;')
        .getSingleOrNull();
    final schema = await db.customSelect('PRAGMA user_version;').getSingle();
    final theme = await SecureStorageOptions.storage.read(
      key: 'app_theme_mode',
    );
    final tableRows = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'table' "
          "AND name NOT LIKE 'sqlite_%' ORDER BY name;",
        )
        .get();
    final tableCounts = <String>[];
    for (final tableRow in tableRows) {
      final table = tableRow.read<String>('name');
      tableCounts.add('$table=${await count(db, table)}');
    }

    debugPrint('[SYSTEM-RESTART] snapshot=$phase commit=$_qaCommit');
    debugPrint('[SYSTEM-RESTART] db_path=${file.path}');
    debugPrint('[SYSTEM-RESTART] db_exists=${file.existsSync()} '
        'db_size=${file.existsSync() ? file.lengthSync() : 0} '
        'schema_version=${schema.read<int>('user_version')}');
    debugPrint('[SYSTEM-RESTART] owner_uid=${owner ?? '<null>'} '
        'auth_uid=${authUid ?? '<null>'} install_id=$installId '
        'language_raw=${settings?.read<String>('language') ?? '<null>'} '
        'theme_raw=${theme ?? '<null>'}');
    debugPrint('[SYSTEM-RESTART] totals '
        'accounts=${await count(db, 'accounts', 'deleted_at IS NULL')} '
        'transactions=${await count(db, 'transactions')} '
        'goals=${await count(db, 'goals', 'deleted_at IS NULL')} '
        'budgets=${await count(db, 'budgets', 'deleted_at IS NULL')}');
    debugPrint('[SYSTEM-RESTART] markers '
        'account=${await count(db, 'accounts', "id = '$_accountId' AND deleted_at IS NULL")} '
        'transaction=${await count(db, 'transactions', "id = '$_transactionId'")} '
        'goal=${await count(db, 'goals', "id = '$_goalId' AND deleted_at IS NULL")} '
        'budget=${await count(db, 'budgets', "id = '$_budgetId' AND deleted_at IS NULL")} '
        'default_account=${await count(db, 'accounts', "id = '$_accountId' AND is_default = 1 AND deleted_at IS NULL")}');
    for (var offset = 0; offset < tableCounts.length; offset += 8) {
      final end =
          offset + 8 < tableCounts.length ? offset + 8 : tableCounts.length;
      debugPrint('[SYSTEM-RESTART] table_counts_${offset ~/ 8 + 1}='
          '${tableCounts.sublist(offset, end).join(',')}');
    }
  }

  Future<void> settle(WidgetTester tester,
      {Duration budget = const Duration(seconds: 90)}) async {
    final deadline = DateTime.now().add(budget);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 200));
      if (find.byType(MoneyApp).evaluate().isNotEmpty) return;
    }
    fail('bootstrap did not hand over to MoneyApp');
  }

  Future<void> ensureQaIdentity() async {
    if (_qaEmail.isEmpty || _qaPassword.isEmpty) {
      fail('QA_EMAIL and QA_PASSWORD are required');
    }
    final client = supabase.Supabase.instance.client;
    if (client.auth.currentUser == null) {
      final response = await client.auth
          .signInWithPassword(email: _qaEmail, password: _qaPassword);
      expect(response.user, isNotNull, reason: 'QA sign-in failed');
      await AppSession.instance.setIdentity(
        method: 'email',
        email: _qaEmail,
        userId: response.user!.id,
      );
    }
    if (!AppSession.instance.hasSeenWelcomeManifesto) {
      await AppSession.instance.markWelcomeManifestoSeen();
    }
    if (!AppSession.instance.hasCompletedOnboarding) {
      await AppSession.instance.finishOnboarding();
    }
  }

  Future<void> deleteMarkers(AppDatabase db) async {
    await db.transaction(() async {
      await db.customStatement(
          'DELETE FROM transactions WHERE id = ?;', [_transactionId]);
      await db
          .customStatement('DELETE FROM budgets WHERE id = ?;', [_budgetId]);
      await db.customStatement('DELETE FROM goals WHERE id = ?;', [_goalId]);
      await db
          .customStatement('DELETE FROM accounts WHERE id = ?;', [_accountId]);
    });
  }

  Future<void> assertMarkers(
    AppDatabase db,
    ProviderContainer container,
  ) async {
    final language = await db
        .customSelect('SELECT language FROM user_settings LIMIT 1;')
        .getSingle();
    expect(language.read<String>('language'), 'en');
    expect(
      await SecureStorageOptions.storage.read(key: 'app_theme_mode'),
      'dark',
      reason: 'theme was lost across process restart',
    );
    expect(
      await count(
        db,
        'accounts',
        "id = '$_accountId' AND is_default = 1 AND deleted_at IS NULL",
      ),
      1,
      reason: 'default account selection was lost across process restart',
    );
    for (final entry in <(String, String)>[
      ('accounts', _accountId),
      ('transactions', _transactionId),
      ('goals', _goalId),
      ('budgets', _budgetId),
    ]) {
      expect(await count(db, entry.$1, "id = '${entry.$2}'"), 1,
          reason: '${entry.$1} marker was lost across process restart');
    }
    final notifications =
        await container.read(loadNotificationPreferencesUseCaseProvider).call();
    expect(notifications.inboxState.hasSentJourney('welcome'), isTrue,
        reason: 'the persisted welcome/journey marker was lost');
  }

  testWidgets('system state survives real same-install process restarts',
      (tester) async {
    final phase = await readPhase();
    final runner = BootstrapRunner();
    runApp(StartupApp(runner: runner));
    await settle(tester);

    final container =
        ProviderScope.containerOf(tester.element(find.byType(MoneyApp)));
    final db = container.read(appDatabaseProvider);

    if (phase == 'arm') {
      // The iOS Keychain deliberately survives uninstall. Start this QA-only
      // harness from a known state without relying on simulator erasure, then
      // exclude that deliberate setup cleanup from startup-destructive counts.
      await DataWipeService(db).wipeAll();
      await AppSession.instance.wipeAndReset();
      await ensureQaIdentity();
      await SecureStorageOptions.storage
          .write(key: _ownerKey, value: _staleOwner);
      debugPrint('[SYSTEM-RESTART] armed_stale_owner=true '
          'auth_uid=${supabase.Supabase.instance.client.auth.currentUser?.id}');
    } else if (phase == 'write') {
      expect(supabase.Supabase.instance.client.auth.currentUser, isNotNull,
          reason: 'the authenticated session did not survive the arm restart');
      await deleteMarkers(db);
      await container.read(saveLanguageUseCaseProvider).call('en');
      await container.read(themeModeProvider.notifier).set(ThemeMode.dark);
      final notifications = await container
          .read(loadNotificationPreferencesUseCaseProvider)
          .call();
      await container.read(saveNotificationPreferencesUseCaseProvider).call(
            notifications.copyWith(
              inboxState: notifications.inboxState.markJourneySent(
                'welcome',
                DateTime.now().toUtc(),
              ),
            ),
          );

      final now = DateTime.now().toUtc();
      final account = await container.read(accountRepositoryProvider).create(
            AccountEntity(
              id: _accountId,
              name: 'QA SYSTEM RESTART',
              currency: 'SAR',
              type: AccountType.bank,
              isDefault: false,
              sortOrder: 9001,
              createdAt: now,
              updatedAt: now,
              initialBalanceMoney: Money(123456, 'SAR'),
              currentBalanceMoney: Money(123456, 'SAR'),
            ),
          );
      await container.read(accountRepositoryProvider).setDefault(account.id);
      await container.read(transactionRepositoryProvider).saveTransaction(
            transaction: TransactionEntity(
              id: _transactionId,
              accountId: account.id,
              amountMoney: Money(4242, 'SAR'),
              currency: 'SAR',
              type: TransactionTypeEntity.payment,
              source: TransactionSourceEntity.imported,
              status: TransactionStatus.confirmed,
              occurredAt: now,
              createdAt: now,
              updatedAt: now,
              rawMessage: 'QA SYSTEM RESTART',
              rawMerchant: 'QA SYSTEM RESTART',
              parseConfidence: 1,
            ),
            categoryKey: null,
          );
      await container.read(goalRepositoryProvider).save(
            GoalEntity(
              id: _goalId,
              name: 'QA SYSTEM RESTART',
              accountId: account.id,
              currency: 'SAR',
              targetMoney: Money(500000, 'SAR'),
              savedMoney: Money(10000, 'SAR'),
              lastNotifiedSavedMoney: Money(0, 'SAR'),
              vaultSkin: 'default_vault',
              status: 'active',
              createdAt: now,
            ),
          );
      final category = await db
          .customSelect('SELECT id FROM categories ORDER BY id LIMIT 1;')
          .getSingle();
      await container.read(budgetRepositoryProvider).save(
            BudgetEntity(
              id: _budgetId,
              categoryId: category.read<String>('id'),
              accountId: account.id,
              currency: 'SAR',
              amountMoney: Money(250000, 'SAR'),
              lastNotifiedSpentMoney: Money(0, 'SAR'),
              period: BudgetPeriod.monthly,
              startDate: DateTime.utc(now.year, now.month),
              isActive: true,
              lastNotifiedPeriodStart: DateTime.utc(now.year, now.month),
            ),
          );
      await assertMarkers(db, container);
      await reportSnapshot('after_session_1_writes', db);
    } else if (phase.startsWith('verify-')) {
      await assertMarkers(db, container);
      await reportSnapshot('verified_$phase', db);
    } else if (phase == 'lifecycle') {
      await assertMarkers(db, container);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 1));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(seconds: 2));
      await assertMarkers(db, container);
      await reportSnapshot('after_background_foreground', db);
    } else if (phase == 'logout-login') {
      await assertMarkers(db, container);
      final uid = supabase.Supabase.instance.client.auth.currentUser?.id;
      expect(uid, isNotNull);
      await AppSession.instance.signOut();
      expect(await count(db, 'transactions', "id = '$_transactionId'"), 0,
          reason: 'explicit logout must wipe local financial data');
      await supabase.Supabase.instance.client.auth.signOut();
      await ensureQaIdentity();
      expect(supabase.Supabase.instance.client.auth.currentUser?.id, uid,
          reason: 'same QA user did not log back in');
      expect(await AppSession.instance.readLocalDataOwnerUid(), uid);
      await reportSnapshot('after_logout_login', db);
    } else {
      fail('unknown phase: $phase');
    }

    debugPrint('[SYSTEM-RESTART] DONE phase=$phase');
  });
}
