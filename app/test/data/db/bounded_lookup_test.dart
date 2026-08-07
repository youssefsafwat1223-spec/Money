// Phase-7 Batch-2-A (MALI-029) — tests for the central bounded-ID lookup
// primitive: the chunk-boundary math (pure) and the DB round-trip (bound
// variables only, owner scoping, dedup) at empty / 1 / boundary / boundary+1 /
// 1,000+ / duplicate identifiers.
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/bounded_lookup.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/sql_value_codec.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

/// Counts SELECT statements so "empty input issues no query" is provable.
class _SelectCounter extends QueryInterceptor {
  int selects = 0;
  @override
  Future<List<Map<String, Object?>>> runSelect(
      QueryExecutor executor, String statement, List<Object?> args) {
    selects++;
    return super.runSelect(executor, statement, args);
  }
}

void main() {
  group('chunkForLookup (pure boundary math)', () {
    test('empty input returns no chunks (caller issues no query)', () {
      expect(chunkForLookup<String>(const []), isEmpty);
      expect(chunkForLookup<String>(const [], chunkSize: 3), isEmpty);
    });

    test('one identifier → one chunk of one', () {
      expect(chunkForLookup(['a'], chunkSize: 3), [
        ['a'],
      ]);
    });

    test('two identifiers stay in one chunk under the boundary', () {
      expect(chunkForLookup(['a', 'b'], chunkSize: 3), [
        ['a', 'b'],
      ]);
    });

    test('exact chunk boundary → single full chunk', () {
      final ids = [for (var i = 0; i < 3; i++) 'id-$i'];
      final chunks = chunkForLookup(ids, chunkSize: 3);
      expect(chunks.length, 1);
      expect(chunks.single.length, 3);
    });

    test('boundary + 1 → two chunks (full + remainder)', () {
      final ids = [for (var i = 0; i < 4; i++) 'id-$i'];
      final chunks = chunkForLookup(ids, chunkSize: 3);
      expect(chunks.length, 2);
      expect(chunks[0].length, 3);
      expect(chunks[1].length, 1);
      // Order preserved end-to-end.
      expect(chunks.expand((c) => c).toList(), ids);
    });

    test('1,000+ identifiers split into deterministic chunks', () {
      final ids = [for (var i = 0; i < 1000; i++) 'id-$i'];
      final chunks = chunkForLookup(ids, chunkSize: kSqliteMaxLookupChunk);
      expect(kSqliteMaxLookupChunk, 500);
      expect(chunks.length, 2);
      expect(chunks[0].length, 500);
      expect(chunks[1].length, 500);
      expect(chunks.expand((c) => c).toList(), ids);

      // 1,001 → three chunks (500 + 500 + 1).
      final ids2 = [for (var i = 0; i < 1001; i++) 'id-$i'];
      final chunks2 = chunkForLookup(ids2, chunkSize: kSqliteMaxLookupChunk);
      expect(chunks2.length, 3);
      expect(chunks2.last.length, 1);
    });

    test('duplicate identifiers are de-duplicated before chunking', () {
      final chunks = chunkForLookup(
        ['a', 'b', 'a', 'c', 'b', 'a'],
        chunkSize: 10,
      );
      expect(chunks.single, ['a', 'b', 'c']);
    });

    test('dedupe: false preserves duplicate multiplicity', () {
      final chunks = chunkForLookup(
        ['a', 'a', 'a'],
        chunkSize: 10,
        dedupe: false,
      );
      expect(chunks.single, ['a', 'a', 'a']);
    });

    test('no bound identifier count exceeds the safe chunk size', () {
      final ids = [for (var i = 0; i < 2500; i++) 'id-$i'];
      for (final chunk in chunkForLookup(ids)) {
        expect(chunk.length, lessThanOrEqualTo(kSqliteMaxLookupChunk));
      }
    });
  });

  group('boundPlaceholders', () {
    test('builds a bound placeholder fragment of the requested arity', () {
      expect(boundPlaceholders(1), '?');
      expect(boundPlaceholders(3), '?, ?, ?');
    });
  });

  group('selectByIdChunks / lookupRowsById (DB round-trip)', () {
    late AppDatabase db;
    late _SelectCounter counter;

    setUp(() async {
      counter = _SelectCounter();
      db = await AppDatabase.open(
        executor: NativeDatabase.memory().interceptWith(counter),
        keyStore: _MemoryKeyStore(),
      );
      // Seed a small owner-scoped account set. `metadata` carries a synthetic
      // owner tag so we can prove owner scoping is honoured by the binding.
      final now = dateTimeToSql(DateTime.utc(2026, 1, 1));
      for (var i = 0; i < 6; i++) {
        final owner = i.isEven ? 'owner-A' : 'owner-B';
        await db.customStatement(
          "INSERT INTO accounts(id, name, currency, type, created_at, "
          "updated_at, server_id, metadata) VALUES ('acct-$i', 'A$i', 'SAR', "
          "'bank', '$now', '$now', 'srv-$i', '$owner');",
        );
      }
      counter.selects = 0;
    });

    tearDown(() async {
      await db.close();
    });

    test('empty ids issues no query and returns empty', () async {
      final rows = await selectByIdChunks(
        db,
        const <String>[],
        sql: (ph) => 'SELECT id FROM accounts WHERE server_id IN ($ph)',
      );
      expect(rows, isEmpty);
      expect(counter.selects, 0, reason: 'no SQL for empty input');
    });

    test('one id resolves to its row in a single query', () async {
      final map = await lookupRowsById(
        db,
        ['srv-2'],
        sql: (ph) =>
            'SELECT id, server_id FROM accounts WHERE server_id IN ($ph)',
        keyColumn: 'server_id',
      );
      expect(map.keys, ['srv-2']);
      expect(map['srv-2']!.read<String>('id'), 'acct-2');
      expect(counter.selects, 1);
    });

    test('resolves many ids sharing few queries (chunked)', () async {
      // 6 real + duplicates + misses; chunk size 4 → 2 chunks (dedup=8 distinct).
      final requested = [
        'srv-0', 'srv-1', 'srv-2', 'srv-3', 'srv-4', 'srv-5',
        'srv-2', 'srv-0', // duplicates → deduped
        'srv-missing-1', 'srv-missing-2', // misses → absent from map
      ];
      final map = await lookupRowsById(
        db,
        requested,
        sql: (ph) =>
            'SELECT id, server_id FROM accounts WHERE server_id IN ($ph)',
        keyColumn: 'server_id',
        chunkSize: 4,
      );
      // 8 distinct ids / chunk 4 = 2 chunks = 2 selects (NOT 10).
      expect(counter.selects, 2);
      expect(map.length, 6);
      expect(map['srv-3']!.read<String>('id'), 'acct-3');
      expect(map.containsKey('srv-missing-1'), isFalse);
    });

    test('owner scoping is explicit via trailing bound variable', () async {
      final rows = await selectByIdChunks(
        db,
        ['srv-0', 'srv-1', 'srv-2', 'srv-3'],
        sql: (ph) => 'SELECT id, metadata FROM accounts '
            'WHERE server_id IN ($ph) AND metadata = ?',
        bindings: (idVars) => [...idVars, Variable.withString('owner-A')],
      );
      // Only even indices belong to owner-A (0, 2); 1 and 3 are owner-B.
      final ids = rows.map((r) => r.read<String>('id')).toSet();
      expect(ids, {'acct-0', 'acct-2'});
    });

    test('1,000 requested ids resolve in a bounded number of chunks',
        () async {
      final ids = [
        'srv-0', 'srv-1', // 2 hits
        for (var i = 0; i < 998; i++) 'srv-miss-$i', // 998 misses
      ];
      final map = await lookupRowsById(
        db,
        ids,
        sql: (ph) =>
            'SELECT id, server_id FROM accounts WHERE server_id IN ($ph)',
        keyColumn: 'server_id',
      );
      // 1000 distinct ids / 500 = 2 chunks = 2 selects (NOT 1000).
      expect(counter.selects, 2);
      expect(map.length, 2);
    });
  });
}
