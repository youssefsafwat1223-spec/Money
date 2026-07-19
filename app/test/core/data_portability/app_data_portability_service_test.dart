import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/data_portability/app_data_portability_service.dart';
import 'package:money_companion/core/data_portability/data_portability_models.dart';
import 'package:money_companion/core/data_portability/drift_financial_exporter.dart';
import 'package:money_companion/data/catalog/catalog_daos.dart';
import 'package:money_companion/data/catalog/feature_flag_service.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_category_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';

  @override
  Future<String?> readStoredKey() async => 'test-key';
}

void main() {
  test('generic CSV import is local-first and rerun does not duplicate',
      () async {
    final db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    addTearDown(db.close);
    final flags = FeatureFlagService(
      dao: RemoteFeatureFlagsDao(db),
      installId: 'portability-test',
    );
    final service = AppDataPortabilityService(
      db: db,
      accounts: DriftAccountRepository(db),
      categories: DriftCategoryRepository(db),
      transactions: DriftTransactionRepository(db),
      settings: DriftUserSettingsRepository(db),
      flags: () => flags,
    );
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
    final confirmed = await service.import(
      confirmedPreview,
      ImportMode.merge,
    );
    expect(confirmed.imported, 1);
    final rows = await db
        .customSelect(
          "SELECT source,raw_message FROM transactions WHERE source='imported';",
        )
        .get();
    expect(rows, hasLength(2));
    expect(
        rows.every((row) => row.read<String>('raw_message').isEmpty), isTrue);
  });

  test('mixed primary package merge writes server then mirrors Drift',
      () async {
    final source = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    final target = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    addTearDown(source.close);
    addTearDown(target.close);
    await RemoteFeatureFlagsDao(target).replaceAll([
      RemoteFeatureFlag(
        key: 'accounts_supabase_primary',
        valueType: 'boolean',
        value: 'true',
        rolloutPercent: 100,
        targetCountries: const [],
        isActive: true,
        syncedAt: DateTime.utc(2026, 7, 18),
      ),
    ]);
    final flags = FeatureFlagService(
      dao: RemoteFeatureFlagsDao(target),
      installId: 'mixed-portability-test',
    );
    await flags.init();
    String? invokedFunction;
    Map<String, dynamic>? invokedParams;
    final service = AppDataPortabilityService(
      db: target,
      accounts: DriftAccountRepository(target),
      categories: DriftCategoryRepository(target),
      transactions: DriftTransactionRepository(target),
      settings: DriftUserSettingsRepository(target),
      flags: () => flags,
      invokeRpc: (functionName, params) async {
        invokedFunction = functionName;
        invokedParams = params;
        return {'imported': 7, 'duplicates': 0, 'skipped': 0};
      },
    );
    final file = File(
      '${Directory.systemTemp.path}/qirsh-mixed-${DateTime.now().microsecondsSinceEpoch}.zip',
    );
    await file.writeAsBytes(
      (await DriftFinancialExporter(source).exportFinancialPackage()).bytes,
      flush: true,
    );
    addTearDown(() async {
      if (await file.exists()) await file.delete();
    });

    final preview = await service.inspectFile(file.path);
    expect(preview.canReplace, isFalse);
    final result = await service.import(preview, ImportMode.merge);

    expect(result.imported, 7);
    expect(invokedFunction, 'import_financial_package');
    expect(invokedParams?['p_mode'], 'merge');
    expect(
      await target
          .customSelect(
            'SELECT COUNT(*) AS total FROM financial_import_runs;',
          )
          .map((row) => row.read<int>('total'))
          .getSingle(),
      1,
    );
    await expectLater(
      service.import(preview, ImportMode.replace),
      throwsA(isA<DataPortabilityException>()),
    );
  });
}
