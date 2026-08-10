import 'package:drift/drift.dart';

import '../../core/utils/id_generator.dart';
import '../../domain/entities/suspected_duplicate_entity.dart';
import '../../domain/repositories/suspected_duplicate_repository.dart';
import '../db/app_database.dart';
import '../db/money_codec.dart';
import '../db/sql_value_codec.dart';
import 'drift_repository_support.dart';

class DriftSuspectedDuplicateRepository
    implements SuspectedDuplicateRepository {
  const DriftSuspectedDuplicateRepository(this._db);

  final AppDatabase _db;

  @override
  Future<void> save(SuspectedDuplicateEntity entity) async {
    await _db.customInsert(
      '''
        INSERT OR IGNORE INTO suspected_duplicates(
          id, raw_message, sender_id, existing_transaction_id,
          amount, currency, raw_merchant, occurred_at, card_last4,
          comparison_timestamp, comparison_timestamp_source, duplicate_reason,
          created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      ''',
      variables: [
        Variable.withString(entity.id.isEmpty ? IdGenerator.next() : entity.id),
        Variable.withString(entity.rawMessage),
        entity.senderId != null
            ? Variable.withString(entity.senderId!)
            : const Variable(null),
        Variable.withString(entity.existingTransactionId),
        kMoneyCodec.realVar(entity.amountMoney),
        Variable.withString(entity.currency),
        entity.rawMerchant != null
            ? Variable.withString(entity.rawMerchant!)
            : const Variable(null),
        Variable.withString(dateTimeToSql(entity.occurredAt)),
        entity.cardLast4 != null
            ? Variable.withString(entity.cardLast4!)
            : const Variable(null),
        entity.comparisonTimestamp != null
            ? Variable.withString(dateTimeToSql(entity.comparisonTimestamp!))
            : const Variable(null),
        entity.comparisonTimestampSource != null
            ? Variable.withString(
                comparisonTimestampSourceToSql(
                    entity.comparisonTimestampSource!),
              )
            : const Variable(null),
        entity.duplicateReason != null
            ? Variable.withString(entity.duplicateReason!)
            : const Variable(null),
        Variable.withString(dateTimeToSql(entity.createdAt)),
      ],
    );
  }

  @override
  Future<List<SuspectedDuplicateEntity>> getAll() async {
    final rows = await _db
        .customSelect(
          'SELECT * FROM suspected_duplicates ORDER BY created_at DESC;',
        )
        .get();
    return rows.map(_fromRow).toList();
  }

  @override
  Future<SuspectedDuplicateEntity?> getByExistingTransactionId(
      String txId) async {
    final rows = await _db.customSelect(
      'SELECT * FROM suspected_duplicates WHERE existing_transaction_id = ? LIMIT 1;',
      variables: [Variable.withString(txId)],
    ).get();
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  @override
  Future<void> delete(String id) async {
    await _db.customUpdate(
      'DELETE FROM suspected_duplicates WHERE id = ?;',
      variables: [Variable.withString(id)],
    );
  }

  SuspectedDuplicateEntity _fromRow(QueryRow row) {
    return SuspectedDuplicateEntity(
      id: row.read<String>('id'),
      rawMessage: row.read<String>('raw_message'),
      senderId: row.readNullable<String>('sender_id'),
      existingTransactionId: row.read<String>('existing_transaction_id'),
      amountMoney: kMoneyCodec.readColumn(
        row,
        'amount',
        row.read<String>('currency'),
      ),
      currency: row.read<String>('currency'),
      rawMerchant: row.readNullable<String>('raw_merchant'),
      occurredAt: dateTimeFromSql(row.read<String>('occurred_at')).toLocal(),
      createdAt: dateTimeFromSql(row.read<String>('created_at')).toLocal(),
      cardLast4: row.readNullable<String>('card_last4'),
      comparisonTimestamp: row.readNullable<String>('comparison_timestamp') ==
              null
          ? null
          : dateTimeFromSql(row.read<String>('comparison_timestamp')).toLocal(),
      comparisonTimestampSource: comparisonTimestampSourceFromSql(
        row.readNullable<String>('comparison_timestamp_source'),
      ),
      duplicateReason: row.readNullable<String>('duplicate_reason'),
    );
  }
}
