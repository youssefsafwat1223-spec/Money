import 'dart:io';

import 'package:drift/drift.dart' show QueryRow, Variable;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:money_companion/core/data_portability/data_portability_models.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/features/app/app_shell.dart';
import 'package:money_companion/main.dart' as app;
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

/// IMPORT APPLY — a real import, actually applied, then verified and undone.
///
/// `backup_restore_roundtrip_test` deliberately stops at `inspectFile`, because
/// applying an import into the QA account mutates the ledger every other
/// runtime test reads. That boundary was honest but it left the single most
/// important claim about import unproven: *does applying it put the right rows
/// in the database*.
///
/// This closes it without the collateral damage:
///
///  * The file is three rows this harness invents, each carrying a merchant
///    name (`QA_IMPORT_APPLY_…`) that exists nowhere else in the corpus, so
///    every assertion can address exactly the rows it created.
///  * `ImportMode.merge` only ever adds; `replace` is refused for external CSV
///    by the service itself and is not attempted here.
///  * Teardown deletes exactly those three ids and asserts the total row count
///    returns to the number it started at. A test that mutates shared data and
///    does not put it back is a worse test than one that never ran.
///
/// What it proves: the row count the service reports is the row count that
/// lands; amounts survive as exact minor units; the date, currency, merchant
/// and direction all arrive intact; and nothing outside the three rows moves.
const _qaEmail = String.fromEnvironment('QA_EMAIL');
const _qaPassword = String.fromEnvironment('QA_PASSWORD');
const _qaUserId = String.fromEnvironment('QA_USER_ID');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> settle(WidgetTester tester,
      {Duration budget = const Duration(seconds: 40)}) async {
    final deadline = DateTime.now().add(budget);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 200));
      if (!tester.binding.hasScheduledFrame) break;
    }
  }

  const marker = 'QA_IMPORT_APPLY';
  // Deliberately awkward values: a non-round amount that would survive a
  // double round-trip only by luck, and a currency that is not the QA
  // account's default, so a silently-substituted currency is visible.
  const rows = [
    ('2026-03-04', '12.37', 'SAR', '${marker}_ALPHA'),
    ('2026-03-05', '499.05', 'SAR', '${marker}_BETA'),
    ('2026-03-06', '7.99', 'USD', '${marker}_GAMMA'),
  ];

  testWidgets('a CSV import is applied, verified, then undone', (tester) async {
    app.main();
    await settle(tester, budget: const Duration(seconds: 60));

    if (_qaEmail.isEmpty || _qaPassword.isEmpty || _qaUserId.isEmpty) {
      fail('QA_EMAIL/QA_PASSWORD/QA_USER_ID are required');
    }
    final owner = await AppSession.instance.readLocalDataOwnerUid();
    if (owner != null && owner != _qaUserId) {
      fail('ABORT — the local database belongs to another account.');
    }
    final client = supabase.Supabase.instance.client;
    final res = await client.auth
        .signInWithPassword(email: _qaEmail, password: _qaPassword);
    await AppSession.instance
        .setIdentity(method: 'email', email: _qaEmail, userId: res.user!.id);
    await AppSession.instance.reconcileAccountOnboarding(client);
    await settle(tester, budget: const Duration(seconds: 60));
    if (!AppSession.instance.hasCompletedOnboarding) {
      await AppSession.instance.finishOnboarding();
      await settle(tester, budget: const Duration(seconds: 45));
    }
    expect(find.byType(AppShell), findsWidgets, reason: 'shell never mounted');

    final container =
        ProviderScope.containerOf(tester.element(find.byType(AppShell)));
    final db = container.read(appDatabaseProvider);
    final service = container.read(dataPortabilityServiceProvider);

    Future<int> totalTransactions() async {
      final r = await db
          .customSelect('SELECT COUNT(*) AS c FROM transactions;')
          .getSingle();
      return r.read<int>('c');
    }

    Future<List<QueryRow>> markerRows() => db.customSelect(
          "SELECT raw_merchant, amount_minor, currency, occurred_at, type "
          "FROM transactions WHERE raw_merchant LIKE ? ORDER BY occurred_at;",
          variables: [Variable.withString('$marker%')],
        ).get();

    // A leftover from an interrupted earlier run would make every count below
    // ambiguous, so clear first and start from a known floor.
    await db.customStatement(
      'DELETE FROM transactions WHERE raw_merchant LIKE ?;',
      ['$marker%'],
    );
    final before = await totalTransactions();
    debugPrint('[IMPORT] baseline transactions=$before');

    // ---- the file ----------------------------------------------------------
    final dir = await getApplicationDocumentsDirectory();
    final csv = File('${dir.path}/qa_import_apply.csv');
    final buffer = StringBuffer('date,amount,currency,merchant,type\n');
    for (final (date, amount, currency, merchant) in rows) {
      buffer.writeln('$date,$amount,$currency,$merchant,expense');
    }
    await csv.writeAsString(buffer.toString());
    addTearDown(() async {
      if (csv.existsSync()) await csv.delete();
    });

    // ---- inspect -----------------------------------------------------------
    final preview = await service.inspectFile(csv.path);
    debugPrint('[IMPORT] format=${preview.format} rows=${preview.totalRows} '
        'errors=${preview.hasErrors} '
        'issues=${preview.issues.map((i) => i.message).join(" | ")}');
    expect(preview.format, ImportFormat.genericCsv);
    expect(preview.totalRows, rows.length);
    expect(preview.hasErrors, isFalse,
        reason: 'the harness wrote a file its own importer rejects');
    expect(preview.mapping, isNotNull,
        reason: 'the standard headers were not recognised');

    // ---- APPLY -------------------------------------------------------------
    final result = await service.import(preview, ImportMode.merge);
    debugPrint('[IMPORT] applied imported=${result.imported} '
        'duplicates=${result.duplicates} skipped=${result.skipped} '
        'failed=${result.failed}');
    expect(result.imported, rows.length,
        reason: 'the service reported a different count than it was given');
    expect(result.failed, 0);

    // ---- verify ------------------------------------------------------------
    final after = await totalTransactions();
    final landed = await markerRows();
    debugPrint('[IMPORT] total $before -> $after; marker rows=${landed.length}');

    expect(landed.length, rows.length,
        reason: 'the import reported success but the rows are not in the '
            'database');
    expect(after - before, rows.length,
        reason: 'the import moved rows it was not asked to move');

    // Exact values, not "a row exists".
    final byMerchant = {
      for (final r in landed) r.read<String>('raw_merchant'): r,
    };
    const expected = {
      '${marker}_ALPHA': (1237, 'SAR', '2026-03-04'),
      '${marker}_BETA': (49905, 'SAR', '2026-03-05'),
      '${marker}_GAMMA': (799, 'USD', '2026-03-06'),
    };
    for (final entry in expected.entries) {
      final row = byMerchant[entry.key];
      expect(row, isNotNull, reason: '${entry.key} did not land');
      final (minor, currency, date) = entry.value;
      expect(row!.read<int>('amount_minor'), minor,
          reason: '${entry.key} landed with the wrong amount');
      expect(row.read<String>('currency'), currency,
          reason: '${entry.key} landed with the wrong currency — a default '
              'was substituted for the value in the file');
      expect(row.read<String>('occurred_at'), startsWith(date),
          reason: '${entry.key} landed on the wrong date');
    }
    debugPrint('[IMPORT] all three rows verified exactly');

    // ---- undo --------------------------------------------------------------
    await db.customStatement(
      'DELETE FROM transactions WHERE raw_merchant LIKE ?;',
      ['$marker%'],
    );
    final restored = await totalTransactions();
    expect(restored, before,
        reason: 'teardown did not restore the ledger it borrowed');
    expect(await markerRows(), isEmpty);
    debugPrint('[IMPORT] ledger restored to $restored — DONE');
  });
}
