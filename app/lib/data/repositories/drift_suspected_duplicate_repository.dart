import 'package:drift/drift.dart';

import '../../core/utils/id_generator.dart';
import '../../domain/entities/suspected_duplicate_entity.dart';
import '../../domain/repositories/suspected_duplicate_repository.dart';
import '../db/app_database.dart';

class DriftSuspectedDuplicateRepository implements SuspectedDuplicateRepository {
  const DriftSuspectedDuplicateRepository(this._db);

  final AppDatabase _db;

  @override
  Future<void> save(SuspectedDuplicateEntity entity) async {
    await _db.customInsert(
      '''
        INSERT OR IGNORE INTO suspected_duplicates(
          id, raw_message, sender_id, existing_transaction_id,
          amount, currency, raw_merchant, occurred_at, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
      ''',
      variables: [
        Variable.withString(entity.id.isEmpty ? IdGenerator.next() : entity.id),
        Variable.withString(entity.rawMessage),
        entity.senderId != null
            ? Variable.withString(entity.senderId!)
            : const Variable(null),
        Variable.withString(entity.existingTransactionId),
        Variable.withReal(entity.amount),
        Variable.withString(entity.currency),
        entity.rawMerchant != null
            ? Variable.withString(entity.rawMerchant!)
            : const Variable(null),
        Variable.withString(entity.occurredAt.toUtc().toIso8601String()),
        Variable.withString(entity.createdAt.toUtc().toIso8601String()),
      ],
    );
  }

  @override
  Future<List<SuspectedDuplicateEntity>> getAll() async {
    final rows = await _db.customSelect(
      'SELECT * FROM suspected_duplicates ORDER BY created_at DESC;',
    ).get();
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
      amount: row.read<double>('amount'),
      currency: row.read<String>('currency'),
      rawMerchant: row.readNullable<String>('raw_merchant'),
      occurredAt: DateTime.parse(row.read<String>('occurred_at')).toLocal(),
      createdAt: DateTime.parse(row.read<String>('created_at')).toLocal(),
    );
  }
}
