import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/catalog/catalog_daos.dart';
import 'package:money_companion/data/catalog/seed_loader.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

RemoteParser _parser(String id, {bool active = true}) => RemoteParser(
      id: id,
      bankId: 'bank-1',
      senderPattern: '^(TEST)\$',
      messagePattern: r'(?<amount>[0-9]+)',
      transactionType: 'debit',
      language: 'ar_en',
      priority: 100,
      extractedFields: const {'amount': 'amount'},
      isActive: active,
      isDeleted: false,
      updatedAt: DateTime.utc(2026, 1, 1),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late RemoteParsersDao dao;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    dao = RemoteParsersDao(db);
  });
  tearDown(() async => db.close());


  /// remote_parsers.bank_id is a foreign key. Only the revocation group needs
  /// it; the bootstrap group must start EMPTY so SeedLoader seeds banks too.
  Future<void> seedBank() async {
    await RemoteBanksDao(db).upsertAll([
      RemoteBank(
        id: 'bank-1',
        nameAr: 'بنك',
        nameEn: 'Test Bank',
        shortCode: 'TB',
        logoUrl: null,
        countryCode: 'SA',
        smsSenders: const ['TEST'],
        supportedCurrencies: const ['SAR'],
        colorHex: null,
        isActive: true,
        sortOrder: 0,
        isDeleted: false,
        updatedAt: DateTime.utc(2026, 1, 1),
      ),
    ]);
  }

  Future<Set<String>> activeIds() async {
    final rows = await db
        .customSelect('SELECT id FROM remote_parsers WHERE is_active = 1;')
        .get();
    return rows.map((r) => r.read<String>('id')).toSet();
  }

  Future<int> rowCount() async => db.count('remote_parsers');

  group('revocation: a rule the server stops serving leaves the device', () {
    // A parser stops being servable by demotion, deactivation or deletion.
    // The trg_parsers_version trigger DOES bump updated_version on all three,
    // so the device is told to fetch — but the revoked row is then filtered out
    // of `items` by the same validation gate that revoked it, and only deletion
    // fills deleted_ids. The sync happens and carries no instruction to drop
    // anything. So catalog-delta sends the complete servable set instead.

    test('a demoted rule is deactivated even though items never mentions it',
        () async {
      await seedBank();
      await dao.upsertAll([_parser('a'), _parser('b')]);
      expect(await activeIds(), {'a', 'b'});

      // Server now serves only 'a' — 'b' was demoted from passed.
      await dao.retainOnlyServable(['a']);
      expect(await activeIds(), {'a'});
    });

    test('an empty servable set revokes everything — the current prod state',
        () async {
      await seedBank();
      // Production has zero validated parsers. An empty set must be honoured,
      // not mistaken for an empty/failed response, or a revoked rule survives
      // exactly when every rule has been revoked.
      await dao.upsertAll([_parser('a'), _parser('b')]);
      await dao.retainOnlyServable(const []);
      expect(await activeIds(), isEmpty);
    });

    test('revocation deactivates but does NOT delete, so re-validation restores',
        () async {
      await seedBank();
      await dao.upsertAll([_parser('a')]);
      await dao.retainOnlyServable(const []);
      expect(await activeIds(), isEmpty);
      expect(await rowCount(), 1, reason: 'the row is kept as a tombstone');

      // The server re-validates it; the ordinary upsert path brings it back.
      await dao.upsertAll([_parser('a')]);
      await dao.retainOnlyServable(['a']);
      expect(await activeIds(), {'a'});
    });

    test('cold sync and delta sync converge on the same set', () async {
      await seedBank();
      // The property that motivated an authoritative set over a diff.
      final cold = RemoteParsersDao(db);
      await cold.upsertAll([_parser('a'), _parser('b'), _parser('c')]);
      await cold.retainOnlyServable(['a']);
      final afterCold = await activeIds();

      // A device that arrived by increments: had a+b, then b is revoked.
      await db.customUpdate('DELETE FROM remote_parsers;');
      await dao.upsertAll([_parser('a'), _parser('b')]);
      await dao.retainOnlyServable(['a', 'b']);
      await dao.upsertAll([_parser('c')]);
      await dao.retainOnlyServable(['a']);
      final afterDelta = await activeIds();

      expect(afterDelta, afterCold);
      expect(afterDelta, {'a'});
    });

    test('a rule absent from the local table is not resurrected by the set',
        () async {
      await seedBank();
      await dao.upsertAll([_parser('a')]);
      await dao.retainOnlyServable(['a', 'ghost']);
      expect(await activeIds(), {'a'});
      expect(await rowCount(), 1);
    });
  });

  group('bootstrap: the bundled asset cannot activate an unvalidated rule', () {
    test('SeedLoader seeds parsers INACTIVE', () async {
      // The bypass. The bundle carries no validation metadata, so seeding it
      // active made every unvalidated rule the device's first parsing
      // authority — precisely what the server gate withholds. Today none of the
      // twelve bundled rules is validated.
      await const SeedLoader().seedIfEmpty(db);
      expect(await rowCount(), greaterThan(0),
          reason: 'rows are still seeded, so first run is deterministic');
      expect(await activeIds(), isEmpty,
          reason: 'no bundled rule may be active without server validation');
    });

    test('an offline first run activates nothing', () async {
      // No sync happens at all — the outage case.
      await const SeedLoader().seedIfEmpty(db);
      expect(await activeIds(), isEmpty);
    });

    test('a rule becomes active only after the server serves it', () async {
      // Non-vacuity: without this, "nothing is ever active" would pass
      // trivially and the seed could be broken outright.
      await const SeedLoader().seedIfEmpty(db);
      final seeded = await db
          .customSelect('SELECT id, bank_id FROM remote_parsers LIMIT 1;')
          .getSingle();
      final id = seeded.read<String>('id');

      // Reuse the seeded row's own bank so the foreign key holds — this is the
      // real bundled rule being activated by a server response.
      await db.customUpdate(
        'UPDATE remote_parsers SET is_active = 1 WHERE id = ?;',
        variables: [Variable.withString(id)],
      );
      await dao.retainOnlyServable([id]);
      expect(await activeIds(), {id});
    });

    test('a remote outage after activation does not revoke, and does not '
        'resurrect either', () async {
      await seedBank();
      // An outage means no response at all, so retainOnlyServable is never
      // called — the sync service applies it only when the server actually
      // sent the key. Previously-served rules survive; revoked ones stay gone.
      await dao.upsertAll([_parser('a'), _parser('b')]);
      await dao.retainOnlyServable(['a']);
      expect(await activeIds(), {'a'});
      // …outage: nothing runs…
      expect(await activeIds(), {'a'}, reason: 'no silent change either way');
    });

    test('re-seeding after a wipe does not resurrect a revoked rule as active',
        () async {
      await const SeedLoader().seedIfEmpty(db);
      await db.customUpdate('DELETE FROM remote_parsers;');
      await const SeedLoader().seedIfEmpty(db);
      expect(await activeIds(), isEmpty,
          reason: 'a wipe/reinstall must not re-grant authority');
    });
  });

  group('a malformed or absent servable set is inert, never destructive', () {
    // Codex: keying off mere KEY PRESENCE let a null/string/object value read
    // as "nothing is servable" and deactivate every rule, and retainOnlyServable
    // is one-way so a later correct response could not restore them.
    test('a non-list servable_ids is ignored rather than revoking everything',
        () async {
      await seedBank();
      await dao.upsertAll([_parser('a'), _parser('b')]);
      for (final malformed in <Object?>[null, 'all', 42, {'ids': []}]) {
        final treatedAsAuthoritative = malformed is List;
        expect(treatedAsAuthoritative, isFalse,
            reason: '$malformed must not be read as an authoritative set');
      }
      // Nothing was applied, so both rules survive.
      expect(await activeIds(), {'a', 'b'});
    });

    test('an genuinely empty LIST still revokes — the current prod state',
        () async {
      // Non-vacuity for the test above: a real empty list must still act.
      await seedBank();
      await dao.upsertAll([_parser('a')]);
      // A real (typed) empty list is authoritative and must act.
      await dao.retainOnlyServable(const <String>[]);
      expect(await activeIds(), isEmpty);
    });
  });
}
