import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:money_companion/core/backup/backup_snapshot_builder.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';

  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

void main() {
  late AppDatabase db;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
  });

  tearDown(() => db.close());

  test('backup snapshot excludes transaction raw_message', () async {
    await db.customInsert(
      '''
        INSERT INTO transactions(
          id, amount, currency, merchant_id, raw_merchant, category_id, type,
          source, card_last4, balance_after, occurred_at, raw_message,
          parse_confidence, status, created_at, updated_at
        )
        VALUES (?, 45.0, 'SAR', NULL, 'BURGER BOUTIQUE', NULL, 'payment',
          'bank', '1234', NULL, '2026-06-12T00:00:00.000Z',
          'SECRET RAW BANK MESSAGE', 0.92, 'confirmed',
          '2026-06-12T00:00:00.000Z', '2026-06-12T00:00:00.000Z');
      ''',
      variables: [Variable.withString('tx_backup_privacy')],
    );

    final snapshot = await BackupSnapshotBuilder(db).build();
    final tables = snapshot['tables'] as Map<String, dynamic>;
    final transactions = tables['transactions'] as List<dynamic>;
    final tx = transactions.single as Map<String, Object?>;

    expect(tx.containsKey('raw_message'), isFalse);
    expect(snapshot.toString(), isNot(contains('SECRET RAW BANK MESSAGE')));
  });
}
