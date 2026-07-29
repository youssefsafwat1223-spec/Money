import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_card_repository.dart';
import 'package:money_companion/domain/entities/card_entity.dart';
import 'package:money_companion/engine/parser/card_network.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

// MALI-017: the at-risk detector that warns before a sign-out wipe destroys
// capability-gated, never-synced card data.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late DriftCardRepository cards;
  final now = DateTime.utc(2026, 7, 1);

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    cards = DriftCardRepository(db, outboxQueue: null);
  });
  tearDown(() => db.close());

  CardEntity card(
    String id, {
    String? accountId,
    String? colorTheme,
    String? accentHex,
  }) =>
      CardEntity(
        id: id,
        accountId: accountId,
        last4: id.hashCode.abs().remainder(9000).toString().padLeft(4, '0'),
        network: CardNetwork.visa,
        source: CardSource.manual,
        createdAt: now,
        updatedAt: now,
        colorTheme: colorTheme,
        accentHex: accentHex,
      );

  Future<void> markSynced(String id) => db.customStatement(
        "UPDATE cards SET server_id = 'srv-$id' WHERE id = '$id';",
      );

  test('account-less card counts as at-risk (cloud drops it while flag off)',
      () async {
    await cards.create(card('c1', accountId: null));
    expect(await cards.countCapabilityGatedUnsyncedCards(), 1);
  });

  test('designed card counts as at-risk (design stripped on push)', () async {
    await cards.create(card('c1', accountId: 'acc', colorTheme: 'midnight'));
    expect(await cards.countCapabilityGatedUnsyncedCards(), 1);
    await db.customStatement("DELETE FROM cards;");
    await cards.create(card('c2', accountId: 'acc', accentHex: '#00E5FF'));
    expect(await cards.countCapabilityGatedUnsyncedCards(), 1);
  });

  test('a plain assigned card is NOT at-risk (it syncs normally)', () async {
    await cards.create(card('c1', accountId: 'acc'));
    expect(await cards.countCapabilityGatedUnsyncedCards(), 0);
  });

  test('an already-synced at-risk card is not counted (server has it)',
      () async {
    await cards.create(card('c1', accountId: null));
    await markSynced('c1');
    expect(await cards.countCapabilityGatedUnsyncedCards(), 0);
  });

  test('a soft-deleted at-risk card is not counted', () async {
    await cards.create(card('c1', accountId: null));
    await cards.delete('c1');
    expect(await cards.countCapabilityGatedUnsyncedCards(), 0);
  });

  test('counts every distinct at-risk card', () async {
    await cards.create(card('c1', accountId: null));
    await cards.create(card('c2', accountId: 'acc', colorTheme: 'ocean'));
    await cards.create(card('c3', accountId: 'acc')); // safe
    expect(await cards.countCapabilityGatedUnsyncedCards(), 2);
  });
}
