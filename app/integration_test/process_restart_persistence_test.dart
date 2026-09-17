import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/app/app_shell.dart';
import 'package:money_companion/app.dart';
import 'package:money_companion/main.dart' as app;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// PROCESS RESTART — does written data survive the app being killed and
/// started again on the SAME install?
///
/// ## Why this is not just another integration test
///
/// `flutter test -d <device>` reinstalls the app on every invocation, and iOS
/// replaces the app container on reinstall. So a two-phase test split across
/// two `flutter test` runs measures the INSTALLER, not the app — an earlier
/// attempt did exactly that and reported the database "lost" when nothing had
/// been lost at all.
///
/// This file is therefore built as its own app bundle
/// (`flutter build ios --simulator -t integration_test/…`), installed ONCE with
/// `simctl install`, and then launched repeatedly with `simctl launch`. Between
/// launches the process is killed with `simctl terminate` and — for the reboot
/// case — the whole device is shut down and booted. Nothing reinstalls, so the
/// container, the database file and the Keychain are the same ones throughout.
///
/// The phase cannot be a `--dart-define`: a define is fixed at compile time and
/// both phases must run the SAME binary. `SIMCTL_CHILD_*` environment injection
/// was tried first and did not reach the Dart isolate, so the harness writes the
/// phase into a file in the app's own Documents directory instead — a channel
/// that is trivially observable from both sides, and whose absence is an
/// explicit default rather than a silent one.
///
/// `tool/process_restart_proof.sh` drives the whole sequence and hashes the
/// database file at each step, so "the same file" is asserted rather than
/// assumed.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// Stable across phases and across runs, so `verify` knows what to look for
  /// without anything being handed between processes.
  const markerId = 'qa-restart-marker-0001';
  const markerMerchant = 'QA_RESTART_PROOF';

  /// Written by `tool/process_restart_proof.sh` into the app container before
  /// each launch. Absent means `write`, so running this file through
  /// `flutter test` still does something sensible.
  Future<String> readPhase() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'qa_phase.txt'));
    if (!file.existsSync()) return 'write';
    return file.readAsStringSync().trim();
  }

  Future<void> settle(WidgetTester tester,
      {Duration budget = const Duration(seconds: 60)}) async {
    final deadline = DateTime.now().add(budget);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 200));
      if (!tester.binding.hasScheduledFrame) break;
    }
  }

  /// The database's own path, so the harness can hash the exact file the app
  /// opened rather than guessing at the container layout. `AppDatabase` keeps
  /// the name private, so this reconstructs it from the same directory the
  /// app uses — and reports the path it actually checked, so a wrong guess is
  /// visible rather than silent.
  Future<void> reportDatabaseFile() async {
    final directory = await getApplicationSupportDirectory();
    final file = File(p.join(directory.path, 'money_companion.sqlite'));
    final exists = file.existsSync();
    debugPrint('[RESTART-PROOF] db_path=${file.path}');
    debugPrint('[RESTART-PROOF] db_exists=$exists '
        'db_size=${exists ? file.lengthSync() : 0}');
  }

  testWidgets('restart persistence', (tester) async {
    app.main();
    await settle(tester);
    expect(find.byType(MaterialApp), findsWidgets);

    // The shell is not required — an unauthenticated launch lands on
    // onboarding — but the ProviderScope is, and `StartupApp` only mounts one
    // once bootstrap hands over to `MoneyApp`. Waiting for `MoneyApp` rather
    // than for any element is what distinguishes "the app is up" from "the
    // pre-bootstrap loading screen is up", which has no scope at all.
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (find.byType(MoneyApp).evaluate().isEmpty &&
        DateTime.now().isBefore(deadline)) {
      await settle(tester, budget: const Duration(seconds: 5));
    }
    expect(find.byType(MoneyApp), findsOneWidget,
        reason: 'bootstrap never handed over to the app');
    final container =
        ProviderScope.containerOf(tester.element(find.byType(MoneyApp)));
    final db = container.read(appDatabaseProvider);

    await reportDatabaseFile();
    final phase = await readPhase();
    debugPrint('[RESTART-PROOF] phase_read=$phase');

    if (phase == 'write') {
      final repo = container.read(transactionRepositoryProvider);
      final accounts = await container.read(accountRepositoryProvider).getAll();
      final accountId = accounts.isEmpty ? null : accounts.first.id;

      // Delete first so a re-run of the write phase is idempotent rather than
      // accumulating markers that would make "found" ambiguous.
      await db.customStatement(
        'DELETE FROM transactions WHERE id = ?;',
        [markerId],
      );
      await repo.saveTransaction(
        categoryKey: null,
        transaction: TransactionEntity(
          id: markerId,
          accountId: accountId,
          amountMoney: Money(4242, 'SAR'),
          currency: 'SAR',
          type: TransactionTypeEntity.payment,
          source: TransactionSourceEntity.imported,
          status: TransactionStatus.confirmed,
          occurredAt: DateTime.utc(2026, 9, 17, 12),
          createdAt: DateTime.now().toUtc(),
          updatedAt: DateTime.now().toUtc(),
          rawMerchant: markerMerchant,
          rawMessage: '',
          parseConfidence: 1,
        ),
      );
      // Read it back through a COLD second connection, which re-derives the
      // SQLCipher key from the Keychain and opens the file fresh. A row visible
      // there genuinely reached disk; one visible only through `db` might still
      // be sitting in Drift's own state.
      final cold = await AppDatabase.openSecondary(owner: db);
      final rows = await cold.customSelect(
        'SELECT id FROM transactions WHERE id = ?;',
        variables: [Variable.withString(markerId)],
      ).get();
      await cold.close();
      debugPrint('[RESTART-PROOF] phase=write '
          'wrote=$markerId on_disk=${rows.isNotEmpty}');
      expect(rows, isNotEmpty, reason: 'the marker never reached disk');
    } else {
      final rows = await db.customSelect(
        'SELECT id, raw_merchant FROM transactions WHERE id = ?;',
        variables: [Variable.withString(markerId)],
      ).get();
      final found = rows.isNotEmpty;
      final merchant =
          found ? rows.first.read<String?>('raw_merchant') : '<none>';
      debugPrint('[RESTART-PROOF] phase=$phase '
          'found=$found merchant=$merchant');
      expect(found, isTrue,
          reason: 'the marker written before the restart is gone — '
              'either the write never reached disk or the container '
              'was replaced');
      expect(merchant, markerMerchant);
    }

    // Recorded for both phases: if the shell mounts, the app did not merely
    // open its database, it got all the way to a usable screen.
    debugPrint('[RESTART-PROOF] shell_mounted='
        '${find.byType(AppShell).evaluate().isNotEmpty}');
    debugPrint('[RESTART-PROOF] DONE phase=$phase');
  });
}
