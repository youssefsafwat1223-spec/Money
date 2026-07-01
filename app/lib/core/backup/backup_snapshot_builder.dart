import '../../data/db/app_database.dart';

class BackupSnapshotBuilder {
  const BackupSnapshotBuilder(this._db);

  final AppDatabase _db;

  static const _tables = <String, List<String>>{
    'accounts': [
      'id',
      'name',
      'currency',
      'type',
      'initial_balance',
      'current_balance',
      'is_default',
      'sort_order',
      'created_at',
      'updated_at',
    ],
    'transactions': [
      'id',
      'account_id',
      'amount',
      'currency',
      'merchant_id',
      'raw_merchant',
      'category_id',
      'type',
      'source',
      'card_last4',
      'balance_after',
      'occurred_at',
      'parse_confidence',
      'status',
      'created_at',
      'updated_at',
    ],
    'budgets': [
      'id',
      'account_id',
      'category_id',
      'amount',
      'period',
      'start_date',
      'is_active',
      'alert_80_sent',
      'alert_100_sent',
    ],
    'goals': [
      'id',
      'account_id',
      'name',
      'target_amount',
      'saved_amount',
      'deadline',
      'vault_skin',
      'status',
      'created_at',
    ],
    'goal_contributions': [
      'id',
      'goal_id',
      'amount',
      'created_at',
      'note',
    ],
    'merchant_category_map': [
      'id',
      'merchant_id',
      'category_id',
      'is_user_confirmed',
      'confidence',
      'updated_at',
    ],
    'merchants': [
      'id',
      'raw_name',
      'normalized_name',
      'first_seen_at',
      'last_seen_at',
    ],
    'achievements': [
      'id',
      'key',
      'name_ar',
      'unlocked_at',
      'progress',
    ],
    'streaks': [
      'id',
      'current_streak',
      'longest_streak',
      'last_active_date',
      'freezes_available',
    ],
    'user_settings': [
      'id',
      'country',
      'currency',
      'language',
      'theme',
      'input_method',
      'notifications_json',
      'db_encryption_key_ref',
    ],
    'subscriptions': [
      'id',
      'account_id',
      'merchant_id',
      'name',
      'amount',
      'currency',
      'period',
      'frequency',
      'type',
      'next_due_date',
      'is_confirmed',
      'reminder_on',
      'custom_interval_days',
      'note',
      'created_at',
    ],
  };

  Future<Map<String, dynamic>> build() async {
    final tables = <String, List<Map<String, Object?>>>{};
    for (final entry in _tables.entries) {
      final columns = entry.value.join(', ');
      final rows = await _db.customSelect(
        'SELECT $columns FROM ${entry.key};',
      ).get();
      tables[entry.key] =
          rows.map((row) => Map<String, Object?>.from(row.data)).toList();
    }
    return {
      'version': 1,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'privacy': {
        'rawMessageExcluded': true,
        'serverReadableFinancialData': false,
      },
      'tables': tables,
    };
  }
}
