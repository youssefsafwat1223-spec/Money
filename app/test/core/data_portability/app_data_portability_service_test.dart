import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/data_portability/app_data_portability_service.dart';
import 'package:money_companion/core/data_portability/data_portability_models.dart';
import 'package:money_companion/core/data_portability/drift_financial_exporter.dart';
import 'package:money_companion/core/utils/id_generator.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_category_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';

// MALI-034: data portability is a single Drift-authoritative path. The obsolete
// Supabase-primary server/mixed import RPC + repairAll rebuild branches were
// retired, so there is no `flags`/`invokeRpc`/`repairFinancialCache` wiring and
// no way for a *_supabase_primary flag to reactivate a Supabase-authoritative
// import/export. These regression tests pin that collapse: local round-trip
// fidelity, replace/merge semantics, financial_import_runs idempotency, and the
// absence of any cache-repair path.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

Future<AppDatabase> _openDb() =>
    AppDatabase.open(executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());

AppDataPortabilityService _service(AppDatabase db) => AppDataPortabilityService(
      db: db,
      accounts: DriftAccountRepository(db),
      categories: DriftCategoryRepository(db),
      transactions: DriftTransactionRepository(db),
      settings: DriftUserSettingsRepository(db),
    );

/// Seeds one confirmed transaction into [db] (on the seeded default account) so
/// there is real financial content to export/replace. Identified by [amount].
Future<void> _seedTransaction(
  AppDatabase db, {
  required double amount,
  String currency = 'EGP',
  String merchant = 'متجر الجولة',
}) async {
  final accountId = (await DriftAccountRepository(db).getDefault())?.id;
  final now = DateTime.utc(2026, 7, 18, 10);
  await DriftTransactionRepository(db).saveTransaction(
    transaction: TransactionEntity(
      id: IdGenerator.next(),
      amountMoney: Money.fromLegacyReal(amount, currency),
      currency: currency,
      accountId: accountId,
      rawMerchant: merchant,
      categoryId: null,
      type: TransactionTypeEntity.payment,
      source: TransactionSourceEntity.imported,
      occurredAt: now,
      rawMessage: '',
      parseConfidence: 1,
      status: TransactionStatus.confirmed,
      createdAt: now,
      updatedAt: now,
      note: null,
      direction: TransactionDirectionEntity.debit,
      comparisonTimestamp: now,
    ),
    categoryKey: null,
  );
}

/// Exports [db]'s financial package to a temp .zip and returns its path
/// (auto-deleted on teardown).
Future<String> _exportToFile(AppDatabase db) async {
  final exported = await DriftFinancialExporter(db).exportFinancialPackage();
  final file = File(
    '${Directory.systemTemp.path}/qirsh-${db.hashCode}-'
    '${exported.bytes.length}.zip',
  );
  await file.writeAsBytes(exported.bytes, flush: true);
  addTearDown(() async {
    if (await file.exists()) await file.delete();
  });
  return file.path;
}

Future<int> _countTransactions(AppDatabase db) => db
    .customSelect('SELECT COUNT(*) AS n FROM transactions;')
    .map((r) => r.read<int>('n'))
    .getSingle();

void main() {
  test('generic CSV import is local-first and rerun does not duplicate',
      () async {
    final db = await _openDb();
    addTearDown(db.close);
    final service = _service(db);
    final file = File(
      '${Directory.systemTemp.path}/qirsh-portability-${DateTime.now().microsecondsSinceEpoch}.csv',
    );
    await file.writeAsString(
      'date,amount,currency,merchant,category\n'
      '2026-07-18T10:00:00Z,-25.50,EGP,متجر اختبار,تسوق\n',
      flush: true,
    );
    addTearDown(() async {
      if (await file.exists()) await file.delete();
    });

    final firstPreview = await service.inspectFile(file.path);
    final first = await service.import(firstPreview, ImportMode.merge);
    final secondPreview = await service.inspectFile(file.path);
    final second = await service.import(secondPreview, ImportMode.merge);

    expect(first.imported, 1);
    expect(second.imported, 0);
    expect(second.duplicates, 1);
    final confirmedPreview = secondPreview.copyWith(
      confirmedDuplicateRecordIds: secondPreview.duplicateRecordIds,
    );
    final confirmed = await service.import(confirmedPreview, ImportMode.merge);
    expect(confirmed.imported, 1);
    final rows = await db
        .customSelect(
          "SELECT source,raw_message FROM transactions WHERE source='imported';",
        )
        .get();
    expect(rows, hasLength(2));
  });

  test(
      'qirsh package import applies through the local Drift path only '
      '(no server RPC), recorded in local financial_import_runs', () async {
    final source = await _openDb();
    final target = await _openDb();
    addTearDown(source.close);
    addTearDown(target.close);
    // AppDatabase.open already seeds a default account/categories to export.
    final exported =
        await DriftFinancialExporter(source).exportFinancialPackage();

    final file = File(
      '${Directory.systemTemp.path}/qirsh-local-${DateTime.now().microsecondsSinceEpoch}.zip',
    );
    await file.writeAsBytes(exported.bytes, flush: true);
    addTearDown(() async {
      if (await file.exists()) await file.delete();
    });

    final service = _service(target);
    final preview = await service.inspectFile(file.path);
    // Drift-authoritative: replace is always available (no mixed-source gate).
    expect(preview.canReplace, isTrue);
    final result = await service.import(preview, ImportMode.merge);

    expect(result.cacheRepairPending, isFalse,
        reason: 'no Supabase repair path remains');
    // The local importer records the run for idempotency.
    final runs = await target
        .customSelect('SELECT COUNT(*) AS n FROM financial_import_runs;')
        .map((r) => r.read<int>('n'))
        .getSingle();
    expect(runs, greaterThanOrEqualTo(1));
  });

  test('export reads local Drift financial state directly', () async {
    final db = await _openDb();
    addTearDown(db.close);
    final exported = await _service(db).exportFinancialPackage();
    expect(exported.bytes, isNotEmpty);
    expect(exported.mimeType, isNotEmpty);
  });

  test('qirsh round-trip reproduces a seeded transaction losslessly (Drift only)',
      () async {
    final source = await _openDb();
    final target = await _openDb();
    addTearDown(source.close);
    addTearDown(target.close);
    await _seedTransaction(source, amount: 150.0, currency: 'EGP');

    final path = await _exportToFile(source);
    final service = _service(target);
    final preview = await service.inspectFile(path);
    final result = await service.import(preview, ImportMode.merge);

    expect(result.imported, greaterThanOrEqualTo(1));
    final match = await target
        .customSelect(
          "SELECT currency FROM transactions "
          "WHERE amount = 150.0 AND status != 'ignored';",
        )
        .get();
    expect(match, hasLength(1),
        reason: 'the seeded transaction round-tripped into the target');
    expect(match.single.read<String>('currency'), 'EGP');
  });

  test('replace mode soft-hides pre-existing financial data before importing',
      () async {
    final source = await _openDb(); // fresh: seeded account/categories, no txns
    final target = await _openDb();
    addTearDown(source.close);
    addTearDown(target.close);
    await _seedTransaction(target, amount: 424242.0, merchant: 'قبل الاستبدال');

    final path = await _exportToFile(source);
    final service = _service(target);
    final preview = await service.inspectFile(path);
    final result = await service.import(preview, ImportMode.replace);

    expect(result.cacheRepairPending, isFalse,
        reason: 'replace still has no repair path');
    final status = await target
        .customSelect(
          'SELECT status FROM transactions WHERE amount = 424242.0 LIMIT 1;',
        )
        .map((r) => r.read<String>('status'))
        .getSingle();
    expect(status, 'ignored',
        reason: 'replace soft-hides the pre-existing local transaction');
  });

  test('qirsh import is idempotent — the same package applies exactly once',
      () async {
    final source = await _openDb();
    final target = await _openDb();
    addTearDown(source.close);
    addTearDown(target.close);
    await _seedTransaction(source, amount: 77.0);

    final path = await _exportToFile(source);
    final service = _service(target);

    final first = await service.import(
        await service.inspectFile(path), ImportMode.merge);
    final countAfterFirst = await _countTransactions(target);
    final second = await service.import(
        await service.inspectFile(path), ImportMode.merge);
    final countAfterSecond = await _countTransactions(target);

    expect(second.imported, first.imported,
        reason: 'second import returns the recorded result, not a re-apply');
    expect(countAfterSecond, countAfterFirst,
        reason: 'no rows are applied twice');
    final runs = await target
        .customSelect(
          'SELECT COUNT(*) AS n FROM financial_import_runs;',
        )
        .map((r) => r.read<int>('n'))
        .getSingle();
    expect(runs, 1, reason: 'exactly one run row exists for the package');
  });

  test('re-importing a package with a different mode is rejected', () async {
    final source = await _openDb();
    final target = await _openDb();
    addTearDown(source.close);
    addTearDown(target.close);
    await _seedTransaction(source, amount: 88.0);

    final path = await _exportToFile(source);
    final service = _service(target);
    await service.import(await service.inspectFile(path), ImportMode.merge);

    await expectLater(
      service.import(await service.inspectFile(path), ImportMode.replace),
      throwsA(isA<DataPortabilityException>()),
    );
  });

  test('external CSV import cannot trigger replace mode', () async {
    final db = await _openDb();
    addTearDown(db.close);
    final service = _service(db);
    final file = File(
      '${Directory.systemTemp.path}/qirsh-csv-replace-${DateTime.now().microsecondsSinceEpoch}.csv',
    );
    await file.writeAsString(
      'date,amount,currency,merchant,category\n'
      '2026-07-18T10:00:00Z,-25.50,EGP,متجر,تسوق\n',
      flush: true,
    );
    addTearDown(() async {
      if (await file.exists()) await file.delete();
    });

    final preview = await service.inspectFile(file.path);
    expect(preview.canReplace, isFalse);
    await expectLater(
      service.import(preview, ImportMode.replace),
      throwsA(isA<DataPortabilityException>()),
    );
  });

  test('qirsh canReplace stays true even when the target already holds data',
      () async {
    final source = await _openDb();
    final target = await _openDb();
    addTearDown(source.close);
    addTearDown(target.close);
    // Pre-populate the target: pre-collapse this would have gated replace behind
    // a mixed-source check; that gate is gone.
    await _seedTransaction(target, amount: 5.0);

    final path = await _exportToFile(source);
    final preview = await _service(target).inspectFile(path);
    expect(preview.canReplace, isTrue);
  });

  test('merge import is non-destructive — existing local data is preserved',
      () async {
    final source = await _openDb(); // fresh: seeded account/categories, no txns
    final target = await _openDb();
    addTearDown(source.close);
    addTearDown(target.close);
    await _seedTransaction(target, amount: 313.0, merchant: 'قبل الدمج');

    final path = await _exportToFile(source);
    final service = _service(target);
    await service.import(await service.inspectFile(path), ImportMode.merge);

    final status = await target
        .customSelect(
          'SELECT status FROM transactions WHERE amount = 313.0 LIMIT 1;',
        )
        .map((r) => r.read<String>('status'))
        .getSingle();
    expect(status, 'confirmed',
        reason: 'merge must never soft-hide pre-existing local rows');
  });
}
