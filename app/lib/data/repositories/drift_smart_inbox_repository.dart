import 'package:drift/drift.dart';

import '../../domain/entities/smart_inbox_item_entity.dart';
import '../../domain/repositories/smart_inbox_repository.dart';
import '../db/app_database.dart';
import '../db/sql_value_codec.dart';

class DriftSmartInboxRepository implements SmartInboxRepository {
  const DriftSmartInboxRepository(this._db);
  final AppDatabase _db;

  @override
  Future<List<SmartInboxItemEntity>> getOpen() async {
    final rows = await _db
        .customSelect(
          "SELECT * FROM smart_inbox_items WHERE status = 'open' "
          'AND dismissed_locally = 0 ORDER BY server_created_at DESC;',
        )
        .get();
    return rows.map(_fromRow).toList(growable: false);
  }

  @override
  Future<void> dismiss(String id) => _setStatus(id, 'dismissed', true);

  @override
  Future<void> resolve(String id) => _setStatus(id, 'resolved', false);

  Future<void> _setStatus(String id, String status, bool dismissed) async {
    // pending_sync = 1: تغيير محلي (offline-first) ينتظر الدفع للخادم.
    await _db.customUpdate(
      'UPDATE smart_inbox_items SET status = ?, dismissed_locally = ?, '
      'pending_sync = 1, updated_at = ? WHERE id = ? OR server_id = ?;',
      variables: [
        Variable.withString(status),
        Variable.withInt(boolToSql(dismissed)),
        Variable.withString(dateTimeToSql(DateTime.now().toUtc())),
        Variable.withString(id),
        Variable.withString(id),
      ],
    );
  }

  SmartInboxItemEntity _fromRow(QueryRow row) => SmartInboxItemEntity(
        id: row.read<String>('server_id'),
        transactionId: row.readNullable<String>('transaction_id'),
        payloadId: row.readNullable<String>('payload_id'),
        type: row.read<String>('type'),
        title: row.read<String>('title'),
        body: row.readNullable<String>('body'),
        status: row.read<String>('status'),
        confidence: row.readNullable<double>('confidence'),
        createdAt: dateTimeFromSql(row.read<String>('server_created_at')),
      );
}
