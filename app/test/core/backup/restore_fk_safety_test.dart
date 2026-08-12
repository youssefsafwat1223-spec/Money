import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backup/backup_service.dart';
import 'package:money_companion/core/backup/backup_snapshot_builder.dart';
import 'package:money_companion/core/backup/restore_backup_usecase.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

// MALI-045n — restore must be FK-safe. (A) snapshots back up FK parents FULL so a
// retained child is never orphaned; (B) the restore genuinely suspends FK
// enforcement (outside the txn), sanitizes any dangling reference to satisfy the
// declared FK semantics, verifies with foreign_key_check inside the txn (residual
// violation → rollback), and re-enables enforcement afterward.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppDatabase> open() => AppDatabase.open(
        executor: NativeDatabase.memory(),
        keyStore: _MemoryKeyStore(),
      );

  Future<int> fkEnabled(AppDatabase db) async =>
      (await db.customSelect('PRAGMA foreign_keys;').getSingle())
          .read<int>('foreign_keys');

  Future<List<Map<String, dynamic>>> fkViolations(AppDatabase db) async =>
      (await db.customSelect('PRAGMA foreign_key_check;').get())
          .map((r) => r.data)
          .toList();

  Future<int> count(AppDatabase db, String sql) async =>
      (await db.customSelect('SELECT COUNT(*) AS n FROM $sql;').getSingle())
          .read<int>('n');

  Map<String, dynamic> userSettingsRow() => <String, dynamic>{
        'id': 'settings',
        'country': 'SA',
        'currency': 'SAR',
        'language': 'ar',
        'theme': 'dark',
        'input_method': 'manual',
        'notifications_json': '{}',
        'db_encryption_key_ref': 'ref',
      };

  test(
      'v3 restore of a SOFT-DELETED subscription with a retained active payment '
      'succeeds (parent backed up full, FK-clean)', () async {
    final src = await open();
    addTearDown(src.close);
    await src.customStatement(
      "INSERT INTO merchants(id, raw_name, normalized_name, first_seen_at, "
      "last_seen_at) VALUES ('m1', 'Net', 'net', '2026-01-01', '2026-01-01');",
    );
    // Soft-deleted subscription (deleted_at set) ...
    await src.customStatement(
      "INSERT INTO subscriptions(id, merchant_id, amount, period, is_confirmed, "
      "reminder_on, name, type, currency, frequency, created_at, deleted_at) "
      "VALUES ('sub1', 'm1', 100, 'monthly', 1, 1, 'Net', 'subscription', "
      "'SAR', 'monthly', '2026-01-01', '2026-02-01');",
    );
    // ... with a RETAINED (active) payment.
    await src.customStatement(
      "INSERT INTO bill_payments(id, bill_id, amount, currency, period_start, "
      "period_end, paid_at) VALUES ('pay1', 'sub1', 100, 'SAR', '2026-01-01', "
      "'2026-01-31', '2026-01-15');",
    );
    await backfillNonPlanningMoneyV30(src);

    final snapshot = await BackupSnapshotBuilder(src).build();
    final subs =
        (snapshot['tables'] as Map<String, dynamic>)['subscriptions'] as List;
    expect(subs.any((r) => (r as Map)['id'] == 'sub1'), isTrue,
        reason: 'Part A: the soft-deleted parent is in the snapshot');

    final dst = await open();
    addTearDown(dst.close);
    await RestoreBackupUseCase(dst).call(snapshot);

    expect(await count(dst, "subscriptions WHERE id='sub1'"), 1);
    expect(await count(dst, "bill_payments WHERE id='pay1'"), 1,
        reason: 'retained child restored, not orphaned');
    expect(await fkViolations(dst), isEmpty);
    expect(await fkEnabled(dst), 1, reason: 'enforcement re-enabled after restore');
  });

  test(
      'an orphaned active child (parent genuinely absent) is sanitized away and '
      'the restore still succeeds FK-clean (proves enforcement was suspended)',
      () async {
    final src = await open();
    addTearDown(src.close);
    final snapshot = await BackupSnapshotBuilder(src).build();
    // Inject an orphan: a bill_payment whose parent subscription is NOT present.
    (snapshot['tables'] as Map<String, dynamic>)['bill_payments'] =
        <Map<String, dynamic>>[
      {
        'id': 'orphan_pay',
        'bill_id': 'ghost_sub',
        'amount': 10.0,
        'currency': 'SAR',
        'period_start': '2026-01-01',
        'period_end': '2026-01-31',
        'paid_at': '2026-01-15',
      }
    ];

    final dst = await open();
    addTearDown(dst.close);
    // Would throw FK 787 immediately if enforcement were NOT suspended.
    await RestoreBackupUseCase(dst).call(snapshot);

    expect(await count(dst, "bill_payments WHERE id='orphan_pay'"), 0,
        reason: 'orphan dropped by FK-safe sanitize');
    expect(await fkViolations(dst), isEmpty);
    expect(await fkEnabled(dst), 1);
  });

  test(
      'v2 backup with a transaction referencing a dangling category restores '
      'with the category nulled (SET NULL semantics), transaction preserved',
      () async {
    final snapshot = <String, dynamic>{
      'schemaVersion': 1, // v2/legacy: no categories key
      'tables': <String, dynamic>{
        'accounts': <Map<String, dynamic>>[
          {
            'id': 'acc_v2',
            'name': 'A',
            'currency': 'SAR',
            'type': 'bank',
            'created_at': '2026-01-01',
            'updated_at': '2026-01-01',
          }
        ],
        'transactions': <Map<String, dynamic>>[
          {
            'id': 'tx_v2',
            'account_id': 'acc_v2',
            'amount': 50.0,
            'currency': 'SAR',
            'category_id': 'ghost_cat', // absent on this install
            'type': 'payment',
            'source': 'bank',
            'occurred_at': '2026-01-01',
            'parse_confidence': 0.9,
            'status': 'confirmed',
            'created_at': '2026-01-01',
            'updated_at': '2026-01-01',
          }
        ],
      },
    };

    final dst = await open();
    addTearDown(dst.close);
    await RestoreBackupUseCase(dst).call(snapshot);

    expect(await count(dst, "transactions WHERE id='tx_v2'"), 1,
        reason: 'financial data preserved');
    final cat = (await dst
            .customSelect("SELECT category_id FROM transactions WHERE id='tx_v2';")
            .getSingle())
        .data['category_id'];
    expect(cat, isNull, reason: 'dangling category nulled (ON DELETE SET NULL)');
    expect(await fkViolations(dst), isEmpty);
    expect(await fkEnabled(dst), 1);
  });

  test('a malformed snapshot is rejected BEFORE any destructive delete',
      () async {
    final dst = await open();
    addTearDown(dst.close);
    await dst.customStatement(
      "INSERT INTO accounts(id, name, currency, type, created_at, updated_at) "
      "VALUES ('keep', 'K', 'SAR', 'bank', '2026-01-01', '2026-01-01');",
    );
    await backfillNonPlanningMoneyV30(dst);
    final before = await count(dst, 'accounts');

    await expectLater(
      RestoreBackupUseCase(dst).call(<String, dynamic>{
        'schemaVersion': 3,
        'tables': 'not-a-map',
      }),
      throwsA(isA<BackupException>()),
    );

    expect(await count(dst, 'accounts'), before, reason: 'no delete ran');
    expect(await count(dst, "accounts WHERE id='keep'"), 1);
    expect(await fkEnabled(dst), 1);
  });

  test(
      'a restore that fails mid-way rolls back and leaves the original DB '
      'unchanged, with FK enforcement re-enabled', () async {
    final dst = await open();
    addTearDown(dst.close);
    await dst.customStatement(
      "INSERT INTO accounts(id, name, currency, type, created_at, updated_at) "
      "VALUES ('orig', 'O', 'SAR', 'bank', '2026-01-01', '2026-01-01');",
    );
    await backfillNonPlanningMoneyV30(dst);

    final snapshot = <String, dynamic>{
      'schemaVersion': 3,
      'tables': <String, dynamic>{
        'categories': <Map<String, dynamic>>[
          {
            'id': 'c1',
            'key': 'k1',
            'name_ar': 'x',
            'icon': 'i',
            'color': '#ffffff',
            'is_income': 0,
            'sort_order': 0,
          }
        ],
        'accounts': <Map<String, dynamic>>[
          {
            'id': 'acc_new',
            'name': 'A',
            'currency': 'SAR',
            'type': 'bank',
            'created_at': '2026-01-01',
            'updated_at': '2026-01-01',
          }
        ],
        'user_settings': <Map<String, dynamic>>[userSettingsRow()],
        // This row fails at INSERT (unknown column) → aborts the whole restore.
        'transactions': <Map<String, dynamic>>[
          {'id': 'bad', 'no_such_column': 'boom'}
        ],
      },
    };

    await expectLater(
      RestoreBackupUseCase(dst).call(snapshot),
      throwsA(anything),
    );

    expect(await count(dst, "accounts WHERE id='orig'"), 1,
        reason: 'original row restored by rollback (the DELETE was undone)');
    expect(await count(dst, "accounts WHERE id='acc_new'"), 0,
        reason: 'nothing from the failed restore was committed');
    expect(await fkEnabled(dst), 1,
        reason: 'FK enforcement re-enabled even after failure');
  });
}
