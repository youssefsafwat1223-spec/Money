import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';

/// F-032 / OD-02 — a card must have a canonical identity.
///
/// Today a transaction records only `card_last4`, and the card↔transaction join
/// is the soft composite `(account_id, last4)` — stated in the schema itself
/// (`app_database.dart`: "الربط عبر (account_id, last4)"). `last4` is four
/// digits, so it is not identity:
///
///   * `getByCard(last4)` matches across EVERY account, so two different
///     physical cards that happen to end in the same four digits are merged
///     into one history;
///   * moving a card to another account (`CardRepository.moveToAccount`) updates
///     only the card row — history stays behind, and if the old account later
///     gains a card ending in the same four digits, that history silently
///     re-attaches to a DIFFERENT physical card.
///
/// Both are silent financial mis-attribution: no error, no warning, just money
/// shown under the wrong card.
///
/// OD-02: adopt canonical `card_id`. `last4` may remain display metadata and
/// matching evidence, never identity. Ambiguous rows must never be guessed.
class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

void main() {
  late AppDatabase db;

  Future<void> insertAccount(String id, String name) => db.customStatement(
        "INSERT INTO accounts(id, name, type, currency, is_default, sort_order, "
        "created_at, updated_at) VALUES('$id', '$name', 'bank', 'SAR', 0, 0, "
        "'2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z');",
      );

  Future<void> insertCard(String id, String accountId, String last4) =>
      db.customStatement(
        "INSERT INTO cards(id, account_id, last4, network, source, created_at, "
        "updated_at) VALUES('$id', '$accountId', '$last4', 'visa', 'manual', "
        "'2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z');",
      );

  Future<void> insertTx(String id, String accountId, String last4) =>
      db.customStatement(
        "INSERT INTO transactions(id, amount, amount_minor, currency, type, "
        "source, occurred_at, raw_message, parse_confidence, status, "
        "created_at, updated_at, account_id, card_last4) "
        "VALUES('$id', 10.0, 1000, 'SAR', 'payment', 'imported', "
        "'2026-08-01T00:00:00Z', 'test', 1.0, 'confirmed', "
        "'2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z', '$accountId', '$last4');",
      );

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    await db.customStatement('DELETE FROM transactions;');
    await db.customStatement('DELETE FROM cards;');
    await db.customStatement('DELETE FROM accounts;');
  });
  tearDown(() async => db.close());

  test('transactions carry a canonical card_id column', () async {
    final cols = await db.customSelect('PRAGMA table_info(transactions);').get();
    final names = cols.map((r) => r.read<String>('name')).toSet();
    expect(names, contains('card_id'),
        reason: 'four digits cannot be identity — OD-02 requires card_id');
  });

  test('two cards sharing last4 in DIFFERENT accounts stay separate', () async {
    // The exact merge defect: same four digits, two physically different cards.
    await insertAccount('acc-a', 'A');
    await insertAccount('acc-b', 'B');
    await insertCard('card-a', 'acc-a', '1234');
    await insertCard('card-b', 'acc-b', '1234');
    await insertTx('tx-a', 'acc-a', '1234');
    await insertTx('tx-b', 'acc-b', '1234');

    await db.backfillCardIdentity();

    final repo = DriftTransactionRepository(db);
    final aHistory = await repo.getByCardId('card-a');
    final bHistory = await repo.getByCardId('card-b');

    expect(aHistory.map((t) => t.id), ['tx-a']);
    expect(bHistory.map((t) => t.id), ['tx-b'],
        reason: 'getByCard(last4) used to return BOTH — one merged history');
  });

  test('an AMBIGUOUS row is left unassigned, never guessed', () async {
    // A transaction with no account cannot be attributed to one of two cards
    // sharing the same last4. OD-02: never guess a card identity.
    await insertAccount('acc-a', 'A');
    await insertAccount('acc-b', 'B');
    await insertCard('card-a', 'acc-a', '9999');
    await insertCard('card-b', 'acc-b', '9999');
    await insertTx('tx-orphan', 'acc-a', '9999');
    await db.customStatement(
        "UPDATE transactions SET account_id = NULL WHERE id = 'tx-orphan';");

    await db.backfillCardIdentity();

    final row = await db
        .customSelect(
            "SELECT card_id FROM transactions WHERE id = 'tx-orphan';")
        .getSingle();
    expect(row.readNullable<String>('card_id'), isNull,
        reason: 'guessing would silently attach money to the wrong card');
  });

  test('the backfill is idempotent — a second run changes nothing', () async {
    await insertAccount('acc-a', 'A');
    await insertCard('card-a', 'acc-a', '4321');
    await insertTx('tx-1', 'acc-a', '4321');

    final first = await db.backfillCardIdentity();
    final second = await db.backfillCardIdentity();

    expect(first, 1);
    expect(second, 0, reason: 'already-attributed rows must not be rewritten');
  });

  test('history does NOT follow a card moved to another account', () async {
    // Reassignment is where the composite key silently re-homes money. With a
    // canonical card_id, existing history keeps pointing at the same physical
    // card regardless of which account the card now belongs to.
    await insertAccount('acc-a', 'A');
    await insertAccount('acc-b', 'B');
    await insertCard('card-a', 'acc-a', '5555');
    await insertTx('tx-1', 'acc-a', '5555');
    await db.backfillCardIdentity();

    // Move the card to account B, as CardRepository.moveToAccount does.
    await db.customStatement(
        "UPDATE cards SET account_id = 'acc-b' WHERE id = 'card-a';");

    final repo = DriftTransactionRepository(db);
    final history = await repo.getByCardId('card-a');
    expect(history.map((t) => t.id), ['tx-1'],
        reason: 'the transaction still belongs to the same physical card');

    // And a NEW card in the old account with the same last4 must not inherit it.
    await insertCard('card-c', 'acc-a', '5555');
    await db.backfillCardIdentity();
    final inherited = await repo.getByCardId('card-c');
    expect(inherited, isEmpty,
        reason: 'the old history must not silently re-attach to a new card');
  });
}
