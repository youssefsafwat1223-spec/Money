import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

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

  tearDown(() async {
    await db.close();
  });

  test('manual revision stream ticks for custom database writes', () async {
    final firstTick = db.manualRevisionStream.first;
    await db.customInsert(
      '''
        INSERT INTO merchants(id, raw_name, normalized_name, first_seen_at, last_seen_at)
        VALUES (?, 'Live Merchant', 'LIVE_MERCHANT', ?, ?);
      ''',
      variables: [
        Variable.withString('merchant_live_1'),
        Variable.withString('2026-06-28T00:00:00.000Z'),
        Variable.withString('2026-06-28T00:00:00.000Z'),
      ],
    );
    final firstRevision = await firstTick;
    expect(firstRevision, greaterThan(0));

    final secondTick = db.manualRevisionStream.first;
    await db.customUpdate(
      "UPDATE merchants SET raw_name = 'Live Merchant Updated' WHERE id = ?;",
      variables: [Variable.withString('merchant_live_1')],
    );
    final secondRevision = await secondTick;
    expect(secondRevision, greaterThan(firstRevision));

    final thirdTick = db.manualRevisionStream.first;
    await db.customStatement(
      "DELETE FROM merchants WHERE id = 'merchant_live_1';",
    );
    expect(await thirdTick, greaterThan(secondRevision));
  });
}
