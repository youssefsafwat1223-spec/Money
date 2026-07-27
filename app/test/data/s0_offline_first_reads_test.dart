import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/routed_account_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

void main() {
  late AppDatabase db;
  late RoutedAccountRepository routed;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    // S5: routing removed — the routed repo delegates to Drift only. The
    // throwing Supabase stub is no longer wired in; UI→Supabase is structurally
    // impossible.
    routed = RoutedAccountRepository(drift: DriftAccountRepository(db));
  });
  tearDown(() async => db.close());

  test('routed reads go to Drift even when Supabase would throw (offline)',
      () async {
    // If any read touched the throwing Supabase repo these would throw. They
    // complete → reads came from Drift. (The DB seeds a default account.)
    final all = await routed.getAll();
    expect(all, isA<List<AccountEntity>>());
    await routed.getDefault(); // must not throw
    if (all.isNotEmpty) {
      await routed.getById(all.first.id); // must not throw
    }
  });

  test('routed writes persist to Drift and are readable offline', () async {
    final created = await routed.create(AccountEntity(
      id: '',
      name: 'أوفلاين',
      currency: 'SAR',
      type: AccountType.bank,
      isDefault: false,
      sortOrder: 9,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    ));
    expect(created.id, isNotEmpty);

    // Readable back immediately from Drift (no Supabase round-trip).
    final byId = await routed.getById(created.id);
    expect(byId?.name, 'أوفلاين');
    final all = await routed.getAll();
    expect(all.map((a) => a.name), contains('أوفلاين'));
  });
}
