import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backend/rules_client.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/engine/models/transaction_source.dart';
import 'package:money_companion/engine/models/transaction_type.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';

  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
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

  test('localBankProfiles reads schema v2 rule profiles', () async {
    await db.customInsert(
      '''
        INSERT INTO parsing_rules(
          id, bank_key, locale, pattern, field, priority, version, is_active
        )
        VALUES (?, ?, ?, ?, 'remote_json', 0, 7, 1);
      ''',
      variables: [
        Variable.withString('cib_eg:ar-EG:7'),
        Variable.withString('cib_eg'),
        Variable.withString('ar-EG'),
        Variable.withString(
          '{"displayName":"CIB Egypt","country":"EG","locale":"ar-EG",'
          '"senderIds":["CIB Alerts"],"keywords":["cib"],'
          '"currencyAliases":{"جنيه":"EGP"},"ignoreRules":["otp"],'
          '"typeRules":{"payment":["purchase"],"income":["salary"]},'
          '"amountRules":["amount"],"balanceRules":["balance"],'
          '"merchantRules":["at"],"dateRules":["on"],"version":7,'
          '"source":"bank"}',
        ),
      ],
    );

    final profiles =
        await RulesClient(database: db).localBankProfiles(locale: 'ar-EG');

    expect(profiles, hasLength(1));
    final profile = profiles.first;
    expect(profile.bankKey, 'cib_eg');
    expect(profile.country, 'EG');
    expect(profile.locale, 'ar-EG');
    expect(profile.senderIds, ['CIB Alerts']);
    expect(profile.currencyAliases['جنيه'], 'EGP');
    expect(profile.ignoreRules, ['otp']);
    expect(profile.typeRules[TransactionType.payment], ['purchase']);
    expect(profile.typeRules[TransactionType.income], ['salary']);
    expect(profile.amountRules, ['amount']);
    expect(profile.balanceRules, ['balance']);
    expect(profile.merchantRules, ['at']);
    expect(profile.dateRules, ['on']);
    expect(profile.version, 7);
  });

  test('localBankProfiles skips invalid JSON and keeps valid fallback rules',
      () async {
    await db.customInsert(
      '''
        INSERT INTO parsing_rules(
          id, bank_key, locale, pattern, field, priority, version, is_active
        )
        VALUES (?, ?, ?, ?, 'remote_json', 0, 9, 1);
      ''',
      variables: [
        Variable.withString('broken:ar-EG:9'),
        Variable.withString('broken'),
        Variable.withString('ar-EG'),
        Variable.withString('{not-json'),
      ],
    );
    await db.customInsert(
      '''
        INSERT INTO parsing_rules(
          id, bank_key, locale, pattern, field, priority, version, is_active
        )
        VALUES (?, ?, ?, ?, 'remote_json', 0, 1, 1);
      ''',
      variables: [
        Variable.withString('valid:ar-EG:1'),
        Variable.withString('valid'),
        Variable.withString('ar-EG'),
        Variable.withString(
          '{"displayName":"Valid Bank","senderIds":["VALID"]}',
        ),
      ],
    );

    final profiles =
        await RulesClient(database: db).localBankProfiles(locale: 'ar-EG');

    expect(profiles.map((profile) => profile.bankKey), ['valid']);
  });
}
