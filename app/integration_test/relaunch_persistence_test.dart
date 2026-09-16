import 'package:drift/drift.dart' show Variable;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/app/app_shell.dart';
import 'package:money_companion/main.dart' as app;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

/// RELAUNCH PERSISTENCE — does written state reach disk, and can the encrypted
/// database be reopened with nothing warm in memory?
///
/// ## What this proves, and what it does not
///
/// It writes through the shipping repositories, then opens a SECOND database
/// connection via `AppDatabase.openSecondary()` and reads the rows back through
/// it. That connection re-derives the SQLCipher key from the Keychain and opens
/// the file fresh, so a row visible through it genuinely reached disk and the
/// encrypted file genuinely reopens with a key recovered from secure storage.
/// That is the real relaunch risk — not "is Drift caching", but "can the app
/// get back INTO its own encrypted database cold".
///
/// It does NOT prove survival across an app reinstall, and that is worth
/// stating because the obvious way to write this test is wrong. A two-phase
/// version — write in one `flutter test` run, verify in the next — was tried
/// first. It reported both Drift layers LOST and the Keychain SURVIVED. That is
/// not a product defect: `flutter test` reinstalls the app every run, iOS
/// replaces the app container on reinstall, and the Keychain lives outside the
/// container. Any simulator evidence that assumes data carries between
/// `flutter test` invocations is measuring the installer, not the app.
///
/// Still unproven and recorded as such: survival across a real process restart
/// on the same install, and across a device reboot.
const _qaEmail = String.fromEnvironment('QA_EMAIL');
const _qaPassword = String.fromEnvironment('QA_PASSWORD');
const _qaUserId = String.fromEnvironment('QA_USER_ID');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> settle(WidgetTester tester,
      {Duration budget = const Duration(seconds: 30)}) async {
    final deadline = DateTime.now().add(budget);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 150));
      if (!tester.binding.hasScheduledFrame) break;
    }
  }

  Future<bool> waitFor(WidgetTester tester, Finder f,
      {Duration timeout = const Duration(seconds: 90)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 150));
      if (f.evaluate().isNotEmpty) return true;
    }
    return false;
  }

  testWidgets('written state is on disk and the encrypted DB reopens cold',
      (tester) async {
    if (_qaEmail.isEmpty || _qaPassword.isEmpty || _qaUserId.isEmpty) {
      fail('QA_EMAIL/QA_PASSWORD/QA_USER_ID are required');
    }

    app.main();
    await settle(tester, budget: const Duration(seconds: 60));

    final client = supabase.Supabase.instance.client;
    final existingOwner = await AppSession.instance.readLocalDataOwnerUid();
    if (existingOwner != null && existingOwner != _qaUserId) {
      fail('ABORT — the local database belongs to another account.');
    }
    if (client.auth.currentUser == null) {
      final res = await client.auth
          .signInWithPassword(email: _qaEmail, password: _qaPassword);
      expect(res.user, isNotNull, reason: 'QA sign-in failed');
      await AppSession.instance
          .setIdentity(method: 'email', email: _qaEmail, userId: res.user!.id);
    }
    await AppSession.instance.markWelcomeManifestoSeen();
    await settle(tester, budget: const Duration(seconds: 45));
    if (!AppSession.instance.hasCompletedOnboarding) {
      await AppSession.instance.finishOnboarding();
      await settle(tester, budget: const Duration(seconds: 30));
    }
    expect(await waitFor(tester, find.byType(AppShell)), isTrue,
        reason: 'shell never mounted');

    final container =
        ProviderScope.containerOf(tester.element(find.byType(AppShell)));
    final settingsRepo = container.read(userSettingsRepositoryProvider);
    final txRepo = container.read(transactionRepositoryProvider);
    final primaryDb = container.read(appDatabaseProvider);

    final marker =
        'relaunch-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

    // ---- write through the SHIPPING repositories ---------------------------
    final before = await settingsRepo.getSettings();
    await settingsRepo.saveSettings(before.copyWith(displayName: marker));

    final accounts = await container.read(accountRepositoryProvider).getAll();
    expect(accounts, isNotEmpty, reason: 'no account to attach a row to');
    final now = DateTime.now();
    await txRepo.saveTransaction(
      transaction: TransactionEntity(
        id: marker,
        accountId: accounts.first.id,
        amountMoney: Money.fromLegacyReal(1, accounts.first.currency),
        currency: accounts.first.currency,
        type: TransactionTypeEntity.payment,
        status: TransactionStatus.confirmed,
        source: TransactionSourceEntity.imported,
        occurredAt: now,
        createdAt: now,
        updatedAt: now,
        rawMessage: marker,
        parseConfidence: 1,
        rawMerchant: marker,
      ),
      categoryKey: null,
    );

    // Readable through the WARM connection. If this fails, the write itself
    // failed — a different defect from "it never reached disk".
    expect((await settingsRepo.getSettings()).displayName, marker,
        reason: 'the write failed, before persistence is even in play');
    expect(await txRepo.getById(marker), isNotNull,
        reason: 'the write failed, before persistence is even in play');

    // ---- read back through a COLD connection -------------------------------
    final cold = await AppDatabase.openSecondary(owner: primaryDb);
    addTearDown(cold.close);

    final coldSettings = await cold
        .customSelect('SELECT display_name FROM user_settings LIMIT 1;')
        .getSingle();
    final coldRows = await cold.customSelect(
      'SELECT id, raw_merchant FROM transactions WHERE id = ?;',
      variables: [Variable.withString(marker)],
    ).get();

    // Each layer is REPORTED, not asserted one at a time: aborting on the first
    // failure hides whether the others survived, and "which layers came back"
    // is the whole diagnostic value here. That is exactly how the container-wipe
    // finding above was identified rather than guessed at.
    final verdicts = <String, bool>{
      'planning row readable cold':
          coldSettings.read<String?>('display_name') == marker,
      'ledger row readable cold (SQLCipher key recovered from the Keychain)':
          coldRows.length == 1 &&
              coldRows.single.read<String?>('raw_merchant') == marker,
      'keychain data-owner identity intact':
          await AppSession.instance.readLocalDataOwnerUid() == _qaUserId,
    };
    verdicts.forEach((layer, ok) {
      debugPrint('[RELAUNCH] ${ok ? "OK  " : "LOST"}  $layer');
    });

    final lost = verdicts.entries.where((e) => !e.value).map((e) => e.key);
    expect(lost, isEmpty, reason: 'not durable: ${lost.join(", ")}');

    debugPrint('[RELAUNCH] NOT proven here: survival across an app reinstall '
        '(iOS replaces the container), across a real process restart on the '
        'same install, or across a device reboot.');
  });
}
