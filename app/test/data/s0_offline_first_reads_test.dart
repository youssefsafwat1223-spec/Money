import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

void main() {
  late AppDatabase db;
  late DriftAccountRepository repo;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    // S5/MALI-034: the vestigial routing wrapper was removed; the UI reads/
    // writes Drift directly. There is no Supabase repository to reach — a
    // UI→Supabase read is structurally impossible.
    repo = DriftAccountRepository(db);
  });
  tearDown(() async => db.close());

  test('reads are served from Drift offline (no network dependency)', () async {
    // With no backend wired, these complete only because they read Drift.
    // (The DB seeds a default account.)
    final all = await repo.getAll();
    expect(all, isA<List<AccountEntity>>());
    await repo.getDefault(); // must not throw
    if (all.isNotEmpty) {
      await repo.getById(all.first.id); // must not throw
    }
  });

  test('writes persist to Drift and are readable back offline', () async {
    final created = await repo.create(AccountEntity(
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
    final byId = await repo.getById(created.id);
    expect(byId?.name, 'أوفلاين');
    final all = await repo.getAll();
    expect(all.map((a) => a.name), contains('أوفلاين'));
  });
}
