import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_card_repository.dart';
import 'package:money_companion/domain/entities/card_entity.dart';
import 'package:money_companion/domain/errors/repo_exceptions.dart';
import 'package:money_companion/engine/parser/card_network.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

CardEntity _card(String accountId, String last4,
    {CardSource source = CardSource.manual, String? nickname}) {
  final now = DateTime.utc(2026, 7, 21);
  return CardEntity(
    id: '',
    accountId: accountId,
    last4: last4,
    network: CardNetwork.visa,
    source: source,
    nickname: nickname,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  late AppDatabase db;
  late DriftCardRepository repo;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    repo = DriftCardRepository(db);
  });

  tearDown(() async => db.close());

  Future<void> insertConfirmedTx({
    required String id,
    required String accountId,
    required String cardLast4,
    double amount = 100,
    String type = 'payment',
  }) async {
    await db.customStatement(
      '''
        INSERT INTO transactions(
          id, amount, currency, type, source, card_last4, account_id,
          occurred_at, raw_message, parse_confidence, status,
          created_at, updated_at
        ) VALUES (
          '$id', $amount, 'SAR', '$type', 'sms', '$cardLast4', '$accountId',
          '2026-07-20T10:00:00.000Z', 'card $cardLast4 visa', 1.0, 'confirmed',
          '2026-07-20T10:00:00.000Z', '2026-07-20T10:00:00.000Z'
        );
      ''',
    );
  }

  test('normalizeLast4 keeps digits and takes last 4', () {
    expect(normalizeLast4('**1234'), '1234');
    expect(normalizeLast4('card 5678'), '5678');
    expect(normalizeLast4('4907'), '4907');
    expect(normalizeLast4('12'), isNull);
    expect(normalizeLast4(null), isNull);
    expect(normalizeLast4('9999123456'), '3456');
  });

  test('create + getByAccount + findByAccountAndLast4', () async {
    final saved = await repo.create(_card('acc-a', '1234', nickname: 'راتب'));
    expect(saved.id, isNotEmpty);
    expect(saved.last4, '1234');
    expect(saved.nickname, 'راتب');

    final byAccount = await repo.getByAccount('acc-a');
    expect(byAccount, hasLength(1));

    final found = await repo.findByAccountAndLast4('acc-a', '**1234');
    expect(found?.id, saved.id);
  });

  test('duplicate (account,last4) rejected; same last4 in another account OK',
      () async {
    await repo.create(_card('acc-a', '1234'));
    expect(
      () => repo.create(_card('acc-a', '1234')),
      throwsA(isA<ValidationRepoException>()),
    );
    // نفس الأرقام في حساب آخر مسموح.
    final other = await repo.create(_card('acc-b', '1234'));
    expect(other.accountId, 'acc-b');
  });

  test('invalid last4 rejected', () async {
    expect(
      () => repo.create(_card('acc-a', '12')),
      throwsA(isA<ValidationRepoException>()),
    );
  });

  test('update changes metadata, keeps identity', () async {
    final saved = await repo.create(_card('acc-a', '1234'));
    final updated = await repo.update(
      saved.copyWith(nickname: 'سفر', network: CardNetwork.mada),
    );
    expect(updated.id, saved.id);
    expect(updated.nickname, 'سفر');
    expect(updated.network, CardNetwork.mada);
  });

  test('move changes account; historical rows are not touched', () async {
    await insertConfirmedTx(id: 't1', accountId: 'acc-a', cardLast4: '1234');
    final saved = await repo.create(_card('acc-a', '1234'));
    final moved =
        await repo.moveToAccount(cardId: saved.id, newAccountId: 'acc-b');
    expect(moved.accountId, 'acc-b');
    // العملية التاريخية ما زالت على acc-a وتحمل card_last4.
    final row = await db
        .customSelect("SELECT account_id, card_last4 FROM transactions "
            "WHERE id = 't1';")
        .getSingle();
    expect(row.read<String>('account_id'), 'acc-a');
    expect(row.read<String>('card_last4'), '1234');
  });

  test('delete soft-deletes card and leaves transactions intact', () async {
    await insertConfirmedTx(id: 't1', accountId: 'acc-a', cardLast4: '1234');
    final saved = await repo.create(_card('acc-a', '1234'));
    await repo.delete(saved.id);
    expect(await repo.getById(saved.id), isNull);
    expect(await repo.getAll(), isEmpty);
    // transaction preserved.
    final count = await db
        .customSelect("SELECT COUNT(*) AS c FROM transactions "
            "WHERE id = 't1' AND card_last4 = '1234';")
        .getSingle();
    expect(count.read<int>('c'), 1);
    // بعد الحذف يمكن إنشاء بطاقة جديدة بنفس الأرقام (الفهرس الفريد للنشطة فقط).
    final again = await repo.create(_card('acc-a', '1234'));
    expect(again.id, isNotEmpty);
  });

  group('backfill', () {
    test('creates auto cards per confident account, skips unassigned',
        () async {
      // acc-a confidently owns 1234; 5678 has no account (unassigned).
      await insertConfirmedTx(id: 't1', accountId: 'acc-a', cardLast4: '1234');
      await insertConfirmedTx(id: 't2', accountId: 'acc-a', cardLast4: '1234');
      await db.customStatement(
        '''
          INSERT INTO transactions(
            id, amount, currency, type, source, card_last4,
            occurred_at, raw_message, parse_confidence, status,
            created_at, updated_at
          ) VALUES (
            't3', 50, 'SAR', 'payment', 'sms', '5678',
            '2026-07-20T10:00:00.000Z', 'card 5678', 1.0, 'confirmed',
            '2026-07-20T10:00:00.000Z', '2026-07-20T10:00:00.000Z'
          );
        ''',
      );

      final created = await repo.backfillFromTransactions();
      expect(created, 1);
      final cards = await repo.getByAccount('acc-a');
      expect(cards, hasLength(1));
      expect(cards.single.last4, '1234');
      expect(cards.single.source, CardSource.auto);
    });

    test('SMS auto-link contract: create auto card once, then idempotent',
        () async {
      // Mirrors CapturedMessageProcessor._autoDetectCard: account known + last4
      // present + no existing card → create auto; repeat is a no-op.
      const accountId = 'acc-a';
      const last4 = '1234';
      Future<void> autoLink() async {
        if (await repo.findByAccountAndLast4(accountId, last4) != null) return;
        await repo.create(_card(accountId, last4, source: CardSource.auto));
      }

      await autoLink();
      await autoLink();
      final cards = await repo.getByAccount(accountId);
      expect(cards, hasLength(1));
      expect(cards.single.source, CardSource.auto);
    });

    test('is idempotent and never overwrites a manual card', () async {
      await insertConfirmedTx(id: 't1', accountId: 'acc-a', cardLast4: '1234');
      final manual =
          await repo.create(_card('acc-a', '1234', nickname: 'يدوي'));

      final created = await repo.backfillFromTransactions();
      expect(created, 0); // already exists.
      final again = await repo.backfillFromTransactions();
      expect(again, 0);

      final card = await repo.getById(manual.id);
      expect(card?.nickname, 'يدوي');
      expect(card?.source, CardSource.manual);
    });
  });
}
