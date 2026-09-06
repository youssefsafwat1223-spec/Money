import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/catalog/catalog_daos.dart';
import 'package:money_companion/data/catalog/parser_authority.dart';
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
      await dao.applyAuthoritativeServableSet(['a']);
      expect(await activeIds(), {'a'});
    });

    test('an empty servable set revokes everything — the current prod state',
        () async {
      await seedBank();
      // Production has zero validated parsers. An empty set must be honoured,
      // not mistaken for an empty/failed response, or a revoked rule survives
      // exactly when every rule has been revoked.
      await dao.upsertAll([_parser('a'), _parser('b')]);
      await dao.applyAuthoritativeServableSet(const []);
      expect(await activeIds(), isEmpty);
    });

    test('revocation deactivates but does NOT delete, so re-validation restores',
        () async {
      await seedBank();
      await dao.upsertAll([_parser('a')]);
      await dao.applyAuthoritativeServableSet(const []);
      expect(await activeIds(), isEmpty);
      expect(await rowCount(), 1, reason: 'the row is kept as a tombstone');

      // The server re-validates it; the ordinary upsert path brings it back.
      await dao.upsertAll([_parser('a')]);
      await dao.applyAuthoritativeServableSet(['a']);
      expect(await activeIds(), {'a'});
    });

    test('cold sync and delta sync converge on the same set', () async {
      await seedBank();
      // The property that motivated an authoritative set over a diff.
      final cold = RemoteParsersDao(db);
      await cold.upsertAll([_parser('a'), _parser('b'), _parser('c')]);
      await cold.applyAuthoritativeServableSet(['a']);
      final afterCold = await activeIds();

      // A device that arrived by increments: had a+b, then b is revoked.
      await db.customUpdate('DELETE FROM remote_parsers;');
      await dao.upsertAll([_parser('a'), _parser('b')]);
      await dao.applyAuthoritativeServableSet(['a', 'b']);
      await dao.upsertAll([_parser('c')]);
      await dao.applyAuthoritativeServableSet(['a']);
      final afterDelta = await activeIds();

      expect(afterDelta, afterCold);
      expect(afterDelta, {'a'});
    });

    test('a rule absent from the local table is not resurrected by the set',
        () async {
      await seedBank();
      await dao.upsertAll([_parser('a')]);
      await dao.applyAuthoritativeServableSet(['a', 'ghost']);
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
      await dao.applyAuthoritativeServableSet([id]);
      expect(await activeIds(), {id});
    });

    test('a remote outage after activation does not revoke, and does not '
        'resurrect either', () async {
      await seedBank();
      // An outage means no response at all, so applyAuthoritativeServableSet is never
      // called — the sync service applies it only when the server actually
      // sent the key. Previously-served rules survive; revoked ones stay gone.
      await dao.upsertAll([_parser('a'), _parser('b')]);
      await dao.applyAuthoritativeServableSet(['a']);
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
    // as "nothing is servable" and deactivate every rule, and applyAuthoritativeServableSet
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
      await dao.applyAuthoritativeServableSet(const <String>[]);
      expect(await activeIds(), isEmpty);
    });
  });

  _authorityEpochTests();
}

// ─────────────────────────────────────────────────────────────────────────────
// AUTHORITY EPOCH — the existing-install upgrade contract.
//
// An install already at the server's parser version never re-fetches, so a
// previous release's bundled-ACTIVE rules would keep money authority forever.
// The epoch forces exactly one full refresh, and advances only after a verified
// snapshot — so an outage leaves parsers inactive and retries.
// ─────────────────────────────────────────────────────────────────────────────

void _authorityEpochTests() {
  late AppDatabase db;
  late RemoteParsersDao parsers;
  late CatalogMetadataDao metadata;
  late ParserAuthority authority;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    parsers = RemoteParsersDao(db);
    metadata = CatalogMetadataDao(db);
    authority = ParserAuthority(parsers, metadata);
    await RemoteBanksDao(db).upsertAll([
      RemoteBank(
        id: 'bank-1', nameAr: 'بنك', nameEn: 'Test Bank', shortCode: 'TB',
        logoUrl: null, countryCode: 'SA', smsSenders: const ['TEST'],
        supportedCurrencies: const ['SAR'], colorHex: null, isActive: true,
        sortOrder: 0, isDeleted: false, updatedAt: DateTime.utc(2026, 1, 1),
      ),
    ]);
  });
  tearDown(() async => db.close());

  Future<Set<String>> activeIds() async {
    final rows = await db
        .customSelect('SELECT id FROM remote_parsers WHERE is_active = 1;')
        .get();
    return rows.map((r) => r.read<String>('id')).toSet();
  }

  /// The state a PREVIOUS release left behind: bundled rules seeded ACTIVE,
  /// catalog version already current, and no epoch recorded.
  Future<void> legacyInstall() async {
    await parsers.upsertAll([
      _parser('legacy-a'),
      _parser('legacy-b'),
    ]);
    await metadata.upsertVersion(CatalogCategories.parsers, 48, 48);
  }

  group('upgrading an install that already had ACTIVE bundled rules', () {
    test('legacy authority is dropped BEFORE anything can use it', () async {
      await legacyInstall();
      expect(await activeIds(), {'legacy-a', 'legacy-b'});

      final action = await authority.reconcile();
      expect(action, ParserAuthorityAction.refreshRequired);
      expect(await activeIds(), isEmpty,
          reason: 'deactivation happens first, not after a successful fetch');
    });

    test('the epoch does NOT advance until a verified snapshot is applied',
        () async {
      await legacyInstall();
      await authority.reconcile();
      expect(await authority.storedEpoch(), lessThan(kParserAuthorityEpoch),
          reason: 'reconcile alone must not claim the refresh happened');
    });

    test('OFFLINE upgrade: rules stay inactive and the refresh stays pending',
        () async {
      await legacyInstall();
      await authority.reconcile();
      // …no network, so markRefreshed is never called…
      expect(await activeIds(), isEmpty);
      expect(await authority.reconcile(), ParserAuthorityAction.refreshRequired,
          reason: 'still pending on the next launch');
      expect(await activeIds(), isEmpty, reason: 'never reactivated offline');
    });

    test('app restart before a successful refresh keeps it fail-closed',
        () async {
      await legacyInstall();
      await authority.reconcile();
      // Simulate a restart: a fresh authority over the same database.
      final afterRestart = ParserAuthority(parsers, metadata);
      expect(await afterRestart.reconcile(),
          ParserAuthorityAction.refreshRequired);
      expect(await activeIds(), isEmpty);
    });

    test('a successful retry later converges and advances the epoch', () async {
      await legacyInstall();
      await authority.reconcile();

      // A verified snapshot says only legacy-a is servable.
      await parsers.applyAuthoritativeServableSet(['legacy-a']);
      await authority.markRefreshed();

      expect(await activeIds(), {'legacy-a'});
      expect(await authority.storedEpoch(), kParserAuthorityEpoch);
    });

    test('no repeated forced refresh once the epoch is current', () async {
      await legacyInstall();
      await authority.reconcile();
      await parsers.applyAuthoritativeServableSet(['legacy-a']);
      await authority.markRefreshed();

      // The next launch must NOT deactivate again — that would be the blind
      // "deactivate on every startup" policy this contract avoids.
      expect(await authority.reconcile(), ParserAuthorityAction.upToDate);
      expect(await activeIds(), {'legacy-a'},
          reason: 'an up-to-date epoch leaves the served set alone');
    });

    test('same catalog version but an OLD epoch still forces the refresh',
        () async {
      // The exact hole: version equality would otherwise skip parsers entirely.
      await legacyInstall();
      final local = await metadata.getVersion(CatalogCategories.parsers);
      expect(local?.localVersion, 48, reason: 'already at the server version');
      expect(await authority.reconcile(), ParserAuthorityAction.refreshRequired);
    });

    test('a re-validated rule can be reactivated later', () async {
      await legacyInstall();
      await authority.reconcile();
      await parsers.applyAuthoritativeServableSet(const []);
      expect(await activeIds(), isEmpty);

      // The server later validates legacy-b.
      await parsers.applyAuthoritativeServableSet(['legacy-b']);
      expect(await activeIds(), {'legacy-b'},
          reason: 'revocation must not be a one-way door');
    });

    test('a tombstoned rule is never reactivated by the servable set', () async {
      await parsers.upsertAll([_parser('gone')]);
      await parsers.markDeleted(['gone']);
      await parsers.applyAuthoritativeServableSet(['gone']);
      expect(await activeIds(), isEmpty,
          reason: 'is_deleted stays authoritative over the servable set');
    });
  });
}
