import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/data_portability/app_data_portability_service.dart';
import 'package:money_companion/core/data_portability/data_portability_models.dart';
import 'package:money_companion/core/data_portability/drift_financial_exporter.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_category_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';

// MALI-034: data portability is a single Drift-authoritative path. The obsolete
// Supabase-primary server/mixed import RPC + repairAll rebuild branches were
// retired, so there is no `flags`/`invokeRpc`/`repairFinancialCache` wiring and
// no way for a *_supabase_primary flag to reactivate a Supabase-authoritative
// import/export.

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
}
