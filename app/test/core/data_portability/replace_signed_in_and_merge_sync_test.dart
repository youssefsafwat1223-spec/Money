import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/data_portability/app_data_portability_service.dart';
import 'package:money_companion/core/data_portability/data_portability_models.dart';
import 'package:money_companion/core/data_portability/drift_financial_exporter.dart';
import 'package:money_companion/core/data_portability/drift_financial_importer.dart';
import 'package:money_companion/core/data_portability/qirsh_package_codec.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_category_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';

import '../../harness/seed_test_account.dart';

/// Replace-import divergence: nothing ever deletes the soft-hidden children
/// (bill payments, goal contributions, plan links) on the server, so for a
/// cloud-owned identity REPLACE is not offered. Guests keep it. MERGE must
/// record sync intent for the children it inserts.
class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

Future<AppDatabase> _database() => seededDb(AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    ));

const _t = '2026-07-18T10:00:00.000Z';

Future<void> _seedFull(AppDatabase db) async {
  await db.customStatement('''
    INSERT INTO accounts(id,name,currency,type,is_default,sort_order,created_at,updated_at)
    VALUES('portable-account','حساب مستورد','EGP','bank',0,99,'$_t','$_t');
  ''');
  await db.customStatement('''
    INSERT INTO transactions(
      id,account_id,amount,currency,type,source,occurred_at,raw_message,
      parse_confidence,status,created_at,updated_at,comparison_timestamp,
      comparison_timestamp_source,duplicate_status
    ) VALUES('portable-transaction','portable-account',25,'EGP','payment',
      'imported','$_t','',1,'confirmed','$_t','$_t','$_t','received_at','normal');
  ''');
  await db.customStatement('''
    INSERT INTO merchants(id,raw_name,normalized_name,first_seen_at,last_seen_at)
    VALUES('portable-merchant','خدمة','خدمة','$_t','$_t');
  ''');
  await db.customStatement('''
    INSERT INTO subscriptions(id,account_id,merchant_id,name,amount,currency,period,
      frequency,type,next_due_date,is_confirmed,reminder_on,created_at,status)
    VALUES('portable-subscription','portable-account','portable-merchant','اشتراك',50,'EGP',
      'monthly','monthly','subscription','$_t',1,1,'$_t','active');
  ''');
  await db.customStatement('''
    INSERT INTO bill_payments(id,bill_id,amount,currency,period_start,period_end,
      paid_at,transaction_id,note)
    VALUES('portable-payment','portable-subscription',25,'EGP','$_t','$_t','$_t',
      'portable-transaction','دفعة');
  ''');
  await db.customStatement('''
    INSERT INTO goals(id,account_id,name,currency,target_amount,
      target_amount_minor,saved_amount,saved_amount_minor,
      last_notified_saved_amount_minor,vault_skin,status,created_at)
    VALUES('portable-goal','portable-account','هدف','EGP',1000,100000,100,10000,
      0,'default','active','$_t');
  ''');
  await db.customStatement('''
    INSERT INTO goal_contributions(id,goal_id,amount,amount_minor,created_at,note)
    VALUES('portable-contribution','portable-goal',100,10000,'$_t','مساهمة');
  ''');
  await db.customStatement('''
    INSERT INTO plans(id,name,budget_amount,currency,start_date,end_date,
      account_ids,status,created_at)
    VALUES('portable-plan','خطة',2000,'EGP','$_t','2026-08-18T10:00:00.000Z',
      'portable-account','active','$_t');
  ''');
  await db.customStatement('''
    INSERT INTO plan_transaction_links(plan_id,transaction_id,created_at)
    VALUES('portable-plan','portable-transaction','$_t');
  ''');
  await backfillNonPlanningMoneyV30(db);
}

Future<QirshPackageData> _package(AppDatabase db) async => decodeQirshPackage(
    (await DriftFinancialExporter(db).exportFinancialPackage()).bytes);

AppDataPortabilityService _service(AppDatabase db,
        {required bool cloudOwned}) =>
    AppDataPortabilityService(
      db: db,
      accounts: DriftAccountRepository(db),
      categories: DriftCategoryRepository(db),
      transactions: DriftTransactionRepository(db),
      settings: DriftUserSettingsRepository(db),
      isCloudOwned: () async => cloudOwned,
    );

Future<String> _file(AppDatabase db) async {
  final exported = await DriftFinancialExporter(db).exportFinancialPackage();
  final file = File('${Directory.systemTemp.path}/qirsh-rep-'
      '${DateTime.now().microsecondsSinceEpoch}.zip');
  await file.writeAsBytes(exported.bytes, flush: true);
  addTearDown(() async {
    if (await file.exists()) await file.delete();
  });
  return file.path;
}

Future<String?> _one(AppDatabase db, String sql) async =>
    (await db.customSelect(sql).getSingleOrNull())?.readNullable<String>('v');

void main() {
  group('REPLACE is guest-only', () {
    test(
        'cloud-owned: preview cannot replace; import(replace) is rejected '
        'with a typed error and touches nothing', () async {
      final source = await _database();
      final target = await _database();
      addTearDown(source.close);
      addTearDown(target.close);
      await _seedFull(source);
      await _seedFull(target);
      final service = _service(target, cloudOwned: true);

      final preview = await service.inspectFile(await _file(source));
      expect(preview.canReplace, isFalse);

      await expectLater(
        service.import(preview.copyWith(canReplace: true), ImportMode.replace),
        throwsA(isA<DataPortabilityException>().having((e) => e.code, 'code',
            DataPortabilityError.replaceUnavailableCloud)),
        reason: 'a forged/stale canReplace must not bypass the live check',
      );
      expect(
          await _one(target,
              "SELECT COUNT(*) AS v FROM bill_payments WHERE deleted_at IS NOT NULL;"),
          '0');
      expect(
          await _one(target,
              "SELECT status AS v FROM transactions WHERE id='portable-transaction';"),
          'confirmed');
    });

    test('cloud-owned can still MERGE', () async {
      final source = await _database();
      final target = await _database();
      addTearDown(source.close);
      addTearDown(target.close);
      await _seedFull(source);
      final service = _service(target, cloudOwned: true);
      final result = await service.import(
          await service.inspectFile(await _file(source)), ImportMode.merge);
      expect(result.imported, greaterThan(0));
    });

    test('guest / local-only: replace still offered and works', () async {
      final source = await _database();
      final target = await _database();
      addTearDown(source.close);
      addTearDown(target.close);
      await _seedFull(source);
      final service = _service(target, cloudOwned: false);
      final preview = await service.inspectFile(await _file(source));
      expect(preview.canReplace, isTrue);
      final result = await service.import(preview, ImportMode.replace);
      expect(result.imported, greaterThan(0));
    });
  });

  group('replace soft-hide (local correctness for guests)', () {
    test(
        'already-deleted rows are not re-stamped; re-imported same-id '
        'children keep their prior sync_status', () async {
      final source = await _database();
      final target = await _database();
      addTearDown(source.close);
      addTearDown(target.close);
      await _seedFull(source);
      await _seedFull(target);
      await target.customStatement(
          "UPDATE bill_payments SET sync_status='synced', server_id='srv-bp';");
      await target.customStatement(
          "UPDATE goal_contributions SET sync_status='synced', server_id='srv-gc';");
      // A child that was deleted long ago must keep its original tombstone.
      await target.customStatement('''
        INSERT INTO goal_contributions(id,goal_id,amount,amount_minor,created_at,
          deleted_at) VALUES('old-gone','portable-goal',1,100,'$_t',
          '2020-01-01T00:00:00.000Z');
      ''');

      await DriftFinancialImporter(target)
          .importPackage(await _package(source), ImportMode.replace);

      expect(
          await _one(target,
              "SELECT deleted_at AS v FROM goal_contributions WHERE id='old-gone';"),
          '2020-01-01T00:00:00.000Z',
          reason: 'only live rows are soft-hidden');
      expect(
          await _one(target,
              "SELECT sync_status AS v FROM bill_payments WHERE id='portable-payment';"),
          'synced',
          reason: 'restored child keeps its prior status, not pending');
      expect(
          await _one(target,
              "SELECT sync_status AS v FROM goal_contributions WHERE id='portable-contribution';"),
          'synced');
      expect(
          await _one(target,
              "SELECT deleted_at AS v FROM goal_contributions WHERE id='portable-contribution';"),
          isNull);
    });
  });

  group('MERGE records sync intent for the children it inserts', () {
    PlanningOutboxQueue queue(AppDatabase db) => PlanningOutboxQueue(
          db: db,
          isSyncEnabled: (_) => true,
          getAuthUserId: () async => 'user-1',
          getOwnerUid: () async => 'user-1',
        );

    Future<Map<String, int>> outboxByType(AppDatabase db) async => {
          for (final r in await db
              .customSelect('SELECT entity_type, operation FROM '
                  'planning_sync_outbox ORDER BY entity_type;')
              .get())
            '${r.read<String>('entity_type')}:${r.read<String>('operation')}': 1
        };

    test(
        'new children under an already-synced parent get create intents '
        '(no backfill would ever pick them up)', () async {
      final source = await _database();
      final target = await _database();
      addTearDown(source.close);
      addTearDown(target.close);
      await _seedFull(source);
      final package = await _package(source);
      // Target already has every parent, fully synced, but not the children.
      await DriftFinancialImporter(target)
          .importPackage(package, ImportMode.merge);
      for (final t in const [
        'accounts',
        'subscriptions',
        'goals',
        'plans',
        'transactions'
      ]) {
        await target.customStatement(
            "UPDATE $t SET server_id='srv-$t', sync_status='synced' "
            "WHERE id LIKE 'portable-%';");
      }
      await target.customStatement('DELETE FROM bill_payments;');
      await target.customStatement('DELETE FROM goal_contributions;');
      await target.customStatement('DELETE FROM plan_transaction_links;');
      await target.customStatement('DELETE FROM financial_import_runs;');
      await target.customStatement('DELETE FROM planning_sync_outbox;');

      final result =
          await DriftFinancialImporter(target, planningOutbox: queue(target))
              .importPackage(package, ImportMode.merge);
      expect(result.imported, greaterThanOrEqualTo(3));

      final out = await outboxByType(target);
      expect(
          out.keys,
          containsAll([
            'bill_payment:create',
            'goal_contribution:create',
            'plan_transaction_link:create',
          ]));
    });

    test('children inserted with brand-new parents are also queued', () async {
      final source = await _database();
      final target = await _database();
      addTearDown(source.close);
      addTearDown(target.close);
      await _seedFull(source);
      await target.customStatement('DELETE FROM planning_sync_outbox;');
      await DriftFinancialImporter(target, planningOutbox: queue(target))
          .importPackage(await _package(source), ImportMode.merge);
      final out = await outboxByType(target);
      expect(
          out.keys,
          containsAll([
            'bill_payment:create',
            'goal_contribution:create',
            'plan_transaction_link:create',
          ]));
    });

    test('existing (duplicate) children are skipped: no intent', () async {
      final source = await _database();
      final target = await _database();
      addTearDown(source.close);
      addTearDown(target.close);
      await _seedFull(source);
      await _seedFull(target);
      await target.customStatement('DELETE FROM planning_sync_outbox;');
      await DriftFinancialImporter(target, planningOutbox: queue(target))
          .importPackage(await _package(source), ImportMode.merge);
      final out = await outboxByType(target);
      expect(out.keys.where((k) => k.startsWith('bill_payment')), isEmpty);
      expect(out.keys.where((k) => k.startsWith('goal_contribution')), isEmpty);
    });
  });
}
