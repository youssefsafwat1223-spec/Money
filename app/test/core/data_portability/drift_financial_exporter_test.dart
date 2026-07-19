import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/data_portability/drift_financial_exporter.dart';
import 'package:money_companion/core/data_portability/portable_csv.dart';
import 'package:money_companion/core/data_portability/qirsh_package_codec.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';

  @override
  Future<String?> readStoredKey() async => 'test-key';
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

  test('full export contains every required financial CSV', () async {
    final exported = await DriftFinancialExporter(db).exportFinancialPackage();
    final package = decodeQirshPackage(exported.bytes);

    expect(package.tables.keys, containsAll(qirshPackageTables));
    expect(package.tables['accounts']!.rows, isNotEmpty);
    expect(package.tables['transactions']!.headers,
        isNot(contains('raw_message')));
    expect(package.tables['transactions']!.headers,
        isNot(contains('source_payload_id')));
  });

  test('transaction export contains account and direction but no raw SMS',
      () async {
    final exported = await DriftFinancialExporter(db).exportTransactionsCsv();
    final document = decodePortableCsv(exported.bytes);

    expect(document.headers, containsAll(['account', 'direction', 'category']));
    expect(document.headers, isNot(contains('raw_message')));
  });
}
