import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backend/rules_client.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/engine/models/transaction_source.dart';

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

  tearDown(() async => db.close());

  test('localBankProfiles reads remote_json parsing rules', () async {
    await db.customInsert(
      '''
        INSERT INTO parsing_rules(
          id, bank_key, locale, pattern, field, priority, version, is_active
        )
        VALUES (?, ?, ?, ?, 'remote_json', 0, 1, 1);
      ''',
      variables: [
        Variable.withString('cib_eg:ar-EG:1'),
        Variable.withString('cib_eg'),
        Variable.withString('ar-EG'),
        Variable.withString(
          '{"displayName":"CIB Egypt","keywords":["CIB Alerts"],"source":"bank"}',
        ),
      ],
    );

    final profiles =
        await RulesClient(database: db).localBankProfiles(locale: 'ar-EG');

    expect(profiles, hasLength(1));
    expect(profiles.first.bankKey, 'cib_eg');
    expect(profiles.first.displayName, 'CIB Egypt');
    expect(profiles.first.keywords, ['CIB Alerts']);
    expect(profiles.first.defaultSource, TransactionSource.bank);
  });
}
