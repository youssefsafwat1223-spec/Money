import 'package:drift/drift.dart';

import '../../core/utils/id_generator.dart';
import '../../domain/entities/card_entity.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../../domain/repositories/card_repository.dart';
import '../../domain/services/card_account_grouper.dart';
import '../../engine/parser/card_network.dart';
import '../../features/planning_sync/services/planning_outbox_queue.dart';
import 'drift_transaction_repository.dart';
import '../db/app_database.dart';
import '../db/sql_value_codec.dart';

CardEntity cardFromRow(QueryRow row) {
  return CardEntity(
    id: row.read<String>('id'),
    accountId: row.readNullable<String>('account_id'),
    nickname: row.readNullable<String>('nickname'),
    last4: row.read<String>('last4'),
    network: CardNetwork.values.firstWhere(
      (n) => n.name == row.read<String>('network'),
      orElse: () => CardNetwork.unknown,
    ),
    source: cardSourceFromKey(row.read<String>('source')),
    colorTheme: row.readNullable<String>('color_theme'),
    accentHex: row.readNullable<String>('accent_hex'),
    createdAt: dateTimeFromSql(row.read<String>('created_at')),
    updatedAt: dateTimeFromSql(row.read<String>('updated_at')),
  );
}

class DriftCardRepository implements CardRepository {
  DriftCardRepository(this._db, {PlanningOutboxQueue? outboxQueue})
      : _outboxQueue = outboxQueue;

  final AppDatabase _db;
  final PlanningOutboxQueue? _outboxQueue;

  @override
  Future<List<CardEntity>> getAll() async {
    final rows = await _db
        .customSelect(
          'SELECT * FROM cards WHERE deleted_at IS NULL '
          'ORDER BY created_at ASC;',
        )
        .get();
    return rows.map(cardFromRow).toList();
  }

  @override
  Future<List<CardEntity>> getByAccount(String accountId) async {
    final rows = await _db.customSelect(
      'SELECT * FROM cards WHERE account_id = ? AND deleted_at IS NULL '
      'ORDER BY created_at ASC;',
      variables: [Variable.withString(accountId)],
    ).get();
    return rows.map(cardFromRow).toList();
  }

  @override
  Future<CardEntity?> getById(String id) async {
    final row = await _db.customSelect(
      'SELECT * FROM cards WHERE id = ? AND deleted_at IS NULL LIMIT 1;',
      variables: [Variable.withString(id)],
    ).getSingleOrNull();
    return row == null ? null : cardFromRow(row);
  }

  @override
  Future<CardEntity?> findByAccountAndLast4(
      String accountId, String last4) async {
    final normalized = normalizeLast4(last4);
    if (normalized == null) return null;
    final row = await _db.customSelect(
      'SELECT * FROM cards WHERE account_id = ? AND last4 = ? '
      'AND deleted_at IS NULL LIMIT 1;',
      variables: [
        Variable.withString(accountId),
        Variable.withString(normalized),
      ],
    ).getSingleOrNull();
    return row == null ? null : cardFromRow(row);
  }

  @override
  Future<CardEntity> create(CardEntity card) async {
    return _db.transaction(() async {
      final normalized = normalizeLast4(card.last4);
      if (normalized == null) {
        throw const ValidationRepoException('invalid_last4');
      }
      // فحص التكرار داخل الحساب فقط عند وجود حساب مرتبط؛ البطاقات غير المخصّصة
      // (account_id = NULL) لا تخضع لقيد فريد على (account_id, last4).
      if (card.accountId != null &&
          await findByAccountAndLast4(card.accountId!, normalized) != null) {
        throw const ValidationRepoException('duplicate_card');
      }
      final id = card.id.isEmpty ? IdGenerator.next() : card.id;
      final now = DateTime.now().toUtc();
      await _db.customInsert(
        '''
        INSERT INTO cards(
          id, account_id, nickname, last4, network, source,
          created_at, updated_at, color_theme, accent_hex
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      ''',
        variables: [
          Variable.withString(id),
          card.accountId == null
              ? const Variable<String>(null)
              : Variable.withString(card.accountId!),
          card.nickname == null
              ? const Variable<String>(null)
              : Variable.withString(card.nickname!),
          Variable.withString(normalized),
          Variable.withString(card.network.name),
          Variable.withString(card.source.name),
          Variable.withString(dateTimeToSql(now)),
          Variable.withString(dateTimeToSql(now)),
          card.colorTheme == null
              ? const Variable<String>(null)
              : Variable.withString(card.colorTheme!),
          card.accentHex == null
              ? const Variable<String>(null)
              : Variable.withString(card.accentHex!),
        ],
      );
      final saved = (await getById(id))!;
      await _outboxQueue?.enqueueCard(PlanningSyncOperation.create, saved);
      return saved;
    });
  }

  @override
  Future<CardEntity> update(CardEntity card) async {
    return _db.transaction(() async {
      final normalized = normalizeLast4(card.last4);
      if (normalized == null) {
        throw const ValidationRepoException('invalid_last4');
      }
      // منع تعارض (account, last4) مع بطاقة أخرى نشطة — فقط عند وجود حساب مرتبط.
      if (card.accountId != null) {
        final existing =
            await findByAccountAndLast4(card.accountId!, normalized);
        if (existing != null && existing.id != card.id) {
          throw const ValidationRepoException('duplicate_card');
        }
      }
      await _db.customUpdate(
        '''
        UPDATE cards
        SET account_id = ?, nickname = ?, last4 = ?, network = ?, source = ?,
            color_theme = ?, accent_hex = ?, updated_at = ?
        WHERE id = ? AND deleted_at IS NULL;
      ''',
        variables: [
          card.accountId == null
              ? const Variable<String>(null)
              : Variable.withString(card.accountId!),
          card.nickname == null
              ? const Variable<String>(null)
              : Variable.withString(card.nickname!),
          Variable.withString(normalized),
          Variable.withString(card.network.name),
          Variable.withString(card.source.name),
          card.colorTheme == null
              ? const Variable<String>(null)
              : Variable.withString(card.colorTheme!),
          card.accentHex == null
              ? const Variable<String>(null)
              : Variable.withString(card.accentHex!),
          Variable.withString(dateTimeToSql(DateTime.now().toUtc())),
          Variable.withString(card.id),
        ],
      );
      final saved = await getById(card.id);
      if (saved == null) throw StateError('Card not found: ${card.id}');
      await _outboxQueue?.enqueueCard(PlanningSyncOperation.update, saved);
      return saved;
    });
  }

  @override
  Future<CardEntity> moveToAccount({
    required String cardId,
    required String newAccountId,
  }) async {
    return _db.transaction(() async {
      final card = await getById(cardId);
      if (card == null) throw StateError('Card not found: $cardId');
      // منع التعارض في الحساب الهدف.
      final clash = await findByAccountAndLast4(newAccountId, card.last4);
      if (clash != null && clash.id != cardId) {
        throw const ValidationRepoException('duplicate_card');
      }
      await _db.customUpdate(
        'UPDATE cards SET account_id = ?, updated_at = ? '
        'WHERE id = ? AND deleted_at IS NULL;',
        variables: [
          Variable.withString(newAccountId),
          Variable.withString(dateTimeToSql(DateTime.now().toUtc())),
          Variable.withString(cardId),
        ],
      );
      final saved = (await getById(cardId))!;
      await _outboxQueue?.enqueueCard(PlanningSyncOperation.update, saved);
      return saved;
    });
  }

  @override
  Future<void> delete(String id) async {
    await _db.transaction(() async {
      final card = await getById(id);
      if (card == null) return;
      // حذف ناعم فقط — العمليات تحتفظ بـ card_last4 (لا تُمسّ).
      await _db.customStatement(
        'UPDATE cards SET deleted_at = ${sqlString(dateTimeToSql(DateTime.now().toUtc()))} '
        'WHERE id = ${sqlString(id)};',
      );
      await _outboxQueue?.enqueueCard(PlanningSyncOperation.delete, card);
    });
  }

  @override
  Future<int> backfillFromTransactions() async {
    final txRepo = DriftTransactionRepository(_db);
    final grouping = const CardAccountGrouper()
        .group(await txRepo.getCardAccountBreakdown());
    var created = 0;
    for (final entry in grouping.byAccount.entries) {
      final accountId = entry.key;
      for (final summary in entry.value) {
        final normalized = normalizeLast4(summary.last4);
        if (normalized == null) continue;
        if (await findByAccountAndLast4(accountId, normalized) != null) {
          continue; // موجودة (يدوية أو سبق تعبئتها) — لا نكرّر ولا نمسّها.
        }
        await create(CardEntity(
          id: '',
          accountId: accountId,
          last4: normalized,
          network: summary.network,
          source: CardSource.auto,
          createdAt: DateTime.now().toUtc(),
          updatedAt: DateTime.now().toUtc(),
        ));
        created++;
      }
    }
    return created;
  }
}
