import '../../data/db/app_database.dart';

class BackupSnapshotBuilder {
  const BackupSnapshotBuilder(this._db);

  final AppDatabase _db;
  static const currentSchemaVersion = 2;

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
      'note',
      'occurred_at',
      'parse_confidence',
      'status',
      'created_at',
      'updated_at',
      'foreign_amount',
      'foreign_currency',
      'direction',
      'transaction_time_from_sms',
      'sms_received_at',
      'comparison_timestamp',
      'comparison_timestamp_source',
      'duplicate_status',
      'possible_duplicate_of_transaction_id',
      'duplicate_reason',
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
      'show_on_header',
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
      'auto_save_amount',
      'auto_save_period',
      'auto_save_last_run',
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
      'display_name',
      'phone_number',
      'avatar_path',
      'date_of_birth',
      'country',
      'currency',
      'language',
      'theme',
      'input_method',
      'notifications_json',
      'db_encryption_key_ref',
      'privacy_mode_enabled',
      'ai_consent_granted',
      'cloud_processing_enabled',
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
      'status',
      'total_installments',
      'paid_count',
      'manual_paid_amount',
      'total_purchase_amount',
      'lender_name',
      'interest_rate',
    ],
    'bill_payments': [
      'id',
      'bill_id',
      'amount',
      'currency',
      'period_start',
      'period_end',
      'paid_at',
      'installment_index',
      'transaction_id',
      'note',
    ],
    'plans': [
      'id',
      'name',
      'budget_amount',
      'currency',
      'start_date',
      'end_date',
      'account_ids',
      'card_last4s',
      'status',
      'icon',
      'created_at',
    ],
    'plan_transaction_links': [
      'plan_id',
      'transaction_id',
      'created_at',
    ],
  };

  static const _activeOnlyTables = {
    'accounts',
    'budgets',
    'goals',
    'goal_contributions',
    'subscriptions',
    'bill_payments',
    'plans',
    'plan_transaction_links',
  };

  Future<Map<String, dynamic>> build() async {
    final tables = <String, List<Map<String, Object?>>>{};
    for (final entry in _tables.entries) {
      final columns = entry.value.join(', ');
      final where = _activeOnlyTables.contains(entry.key)
          ? ' WHERE deleted_at IS NULL'
          : '';
      final rows = await _db
          .customSelect(
            'SELECT $columns FROM ${entry.key}$where;',
          )
          .get();
      tables[entry.key] =
          rows.map((row) => Map<String, Object?>.from(row.data)).toList();
    }
    return {
      'version': 2,
      'schemaVersion': currentSchemaVersion,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'privacy': {
        'rawMessageExcluded': true,
        'serverReadableFinancialData': false,
      },
      'tables': tables,
    };
  }
}
