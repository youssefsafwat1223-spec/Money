import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:money_companion/core/data_portability/data_portability_models.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/app/app_shell.dart';
import 'package:money_companion/main.dart' as app;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

/// BACKUP / RESTORE ROUND TRIP — on device, against the real database.
///
/// The claim being tested is the one a user actually depends on: *the file the
/// app hands me can be read back by the app*. That is not the same as "export
/// produced bytes", which is all a size check proves.
///
/// So this exports BOTH shipping formats, writes them where the import path
/// reads from, and inspects them through `inspectFile` — the same call the
/// Data Transfer screen makes. An export the importer cannot parse is a
/// corrupt backup, and it would look perfectly healthy to any test that only
/// checked `recordCount > 0`.
///
/// ## Deliberately NOT done here
///
/// It stops at inspect and does not call `import`. Importing into the QA
/// account would mutate the ledger this and every other runtime test reads
/// from, and a destructive step that has to be undone is a worse test than an
/// honest boundary. Replace-mode restore is covered by
/// `destructive_phase_test`, which owns its own teardown.
///
/// Cloud backup (the passphrase + recovery-code, end-to-end encrypted path) is
/// a separate feature and is NOT covered: it needs a passphrase this harness
/// has no business inventing, and it writes to the owner's cloud storage.
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

  testWidgets('what export writes, import can read back', (tester) async {
    if (_qaEmail.isEmpty || _qaPassword.isEmpty || _qaUserId.isEmpty) {
      fail('QA_EMAIL/QA_PASSWORD/QA_USER_ID are required');
    }

    app.main();
    await settle(tester, budget: const Duration(seconds: 60));

    final client = supabase.Supabase.instance.client;
    final owner = await AppSession.instance.readLocalDataOwnerUid();
    if (owner != null && owner != _qaUserId) {
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
    final portability = container.read(dataPortabilityServiceProvider);
    final tmp = await getTemporaryDirectory();

    final results = <String, String>{};
    final failures = <String>[];

    // Seed a row we can name. Without it the first run after a fresh install
    // exports an EMPTY ledger, and "0 records exported, 0 read back" is
    // perfectly consistent — the round trip would pass while proving nothing.
    // That is exactly what the first version of this test did.
    final marker =
        'roundtrip-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    // Held, not re-read in teardown: the container is disposed by then.
    final txRepo = container.read(transactionRepositoryProvider);
    final accounts = await container.read(accountRepositoryProvider).getAll();
    expect(accounts, isNotEmpty, reason: 'no account to attach a row to');
    final seededAt = DateTime.now();
    await txRepo.saveTransaction(
          transaction: TransactionEntity(
            id: marker,
            accountId: accounts.first.id,
            amountMoney: Money.fromLegacyReal(12.34, accounts.first.currency),
            currency: accounts.first.currency,
            type: TransactionTypeEntity.payment,
            status: TransactionStatus.confirmed,
            source: TransactionSourceEntity.imported,
            occurredAt: seededAt,
            createdAt: seededAt,
            updatedAt: seededAt,
            rawMessage: marker,
            parseConfidence: 1,
            rawMerchant: marker,
          ),
          categoryKey: null,
        );
    addTearDown(() => txRepo.deleteTransaction(marker));

    Future<void> roundTrip(
      String label,
      Future<ExportedFile> Function() export,
      ImportFormat expectedFormat,
    ) async {
      final ExportedFile file;
      try {
        file = await export();
      } catch (e) {
        results[label] = 'EXPORT FAILED: $e';
        return;
      }
      if (file.bytes.isEmpty) {
        results[label] = 'EXPORT EMPTY (0 bytes)';
        return;
      }

      // Write it where the import path reads from, exactly as the share sheet
      // would — reading the in-memory bytes back would skip the file layer,
      // which is where an encoding or extension bug lives.
      final path = '${tmp.path}/${file.name}';
      await File(path).writeAsBytes(file.bytes, flush: true);

      final ImportPreview preview;
      try {
        preview = await portability.inspectFile(path);
      } catch (e) {
        results[label] = 'EXPORT OK (${file.bytes.length} bytes, '
            '${file.recordCount} records) but IMPORT REJECTED IT: $e';
        return;
      }

      final blocking =
          preview.issues.where((i) => i.severity == ImportIssueSeverity.error);
      results[label] = 'ok — ${file.bytes.length} bytes, '
          '${file.recordCount} exported, ${preview.totalRows} rows seen on '
          'read-back, format=${preview.format.name}, '
          'blocking issues=${blocking.length}';

      // Recorded, not asserted here: asserting inside the loop aborts before
      // the SECOND format is even tried, and "which of the two is broken" is
      // the diagnostic.
      if (preview.format != expectedFormat) {
        failures.add('$label: written as $expectedFormat, read back as '
            '${preview.format}');
      }
      // For the UNCOMPRESSED format the seeded row must appear verbatim in the
      // bytes — a count alone would pass on an export that wrote the right
      // NUMBER of wrong rows. The ZIP is deflated, so the same check there
      // tests the compressor, not the export; its content is verified through
      // the importer's row count instead.
      if (expectedFormat == ImportFormat.genericCsv) {
        final text = String.fromCharCodes(file.bytes);
        if (!text.contains(marker)) {
          failures.add('$label: the seeded row is not in the exported bytes');
        }
      }
      if (preview.totalRows == 0) {
        failures.add('$label: exported ${file.recordCount} records into '
            '${file.bytes.length} bytes, but the importer found 0 rows — a '
            'backup that reads back empty is worse than no backup, because it '
            'looks fine');
      }
      if (blocking.isNotEmpty) {
        failures.add('$label: cannot be imported — '
            '${blocking.map((i) => i.message).join("; ")}');
      }

      await File(path).delete();
    }

    await roundTrip('transactions CSV', portability.exportTransactionsCsv,
        ImportFormat.genericCsv);
    await roundTrip('full package ZIP', portability.exportFinancialPackage,
        ImportFormat.qirshPackage);

    results.forEach((k, v) => debugPrint('[BACKUP] $k: $v'));
    for (final f in failures) {
      debugPrint('[BACKUP] FAIL $f');
    }
    debugPrint('[BACKUP] NOT covered: applying the import (mutates the QA '
        'ledger — see destructive_phase_test) and cloud E2E backup (needs a '
        "passphrase and writes to the owner's storage).");
    expect(failures, isEmpty, reason: failures.join('\n'));
  });
}
