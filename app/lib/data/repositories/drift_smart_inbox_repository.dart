import 'dart:convert';

import 'package:drift/drift.dart';

import '../../domain/entities/smart_inbox_item_entity.dart';
import '../../domain/repositories/smart_inbox_repository.dart';
import '../db/app_database.dart';
import '../db/sql_value_codec.dart';

class DriftSmartInboxRepository implements SmartInboxRepository {
  const DriftSmartInboxRepository(this._db);
  final AppDatabase _db;

  /// Persists a native capture that looked financial but could not be parsed.
  ///
  /// The payload id is the durable business key: a crash/re-delivery executes
  /// the same INSERT OR IGNORE and therefore keeps one review card. This is a
  /// local Smart Inbox item (there is no server-authored row to push), while the
  /// raw SMS remains available in [body] for manual recovery.
  Future<String> saveUnprocessableCapture({
    required String payloadId,
    required String rawMessage,
    required String source,
    String? senderId,
    DateTime? receivedAt,
  }) async {
    final itemId = 'local_capture:$payloadId';
    final now = DateTime.now().toUtc();
    final effectiveReceivedAt = (receivedAt ?? now).toUtc();
    await _db.customInsert(
      '''
        INSERT OR IGNORE INTO smart_inbox_items(
          id, server_id, transaction_id, payload_id,
          type, title, body, status, confidence, metadata_json,
          server_created_at, server_updated_at, synced_at,
          dismissed_locally, pending_sync, created_at, updated_at
        ) VALUES (?, ?, NULL, ?, 'needs_review', ?, ?, 'open', NULL, ?,
                  ?, NULL, ?, 0, 0, ?, ?);
      ''',
      variables: [
        Variable.withString(itemId),
        Variable.withString(itemId),
        Variable.withString(payloadId),
        Variable.withString('رسالة بنكية غير مدعومة تحتاج مراجعة'),
        Variable.withString(rawMessage),
        Variable.withString(jsonEncode({
          'capture_disposition': 'unprocessable',
          'source': source,
          if (senderId != null && senderId.isNotEmpty) 'sender_id': senderId,
          'received_at': effectiveReceivedAt.toIso8601String(),
          'local_only': true,
        })),
        Variable.withString(dateTimeToSql(effectiveReceivedAt)),
        Variable.withString(dateTimeToSql(now)),
        Variable.withString(dateTimeToSql(now)),
        Variable.withString(dateTimeToSql(now)),
      ],
    );
    return itemId;
  }

  /// Bare legacy `rejected:<payloadId>` dedup markers are not durable capture
  /// results on their own. This lets the native drain require the deterministic
  /// review row before treating such a marker as safe acknowledgement proof.
  Future<bool> hasUnprocessableCapture(String payloadId) async {
    final itemId = 'local_capture:$payloadId';
    final row = await _db.customSelect(
      '''
        SELECT 1 FROM smart_inbox_items
        WHERE id = ? AND payload_id = ?
        LIMIT 1;
      ''',
      variables: [
        Variable.withString(itemId),
        Variable.withString(payloadId),
      ],
    ).getSingleOrNull();
    return row != null;
  }

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
