import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../../data/db/app_database.dart';
import 'supabase_config.dart';

class RulesClient {
  RulesClient({
    required AppDatabase database,
    supabase.SupabaseClient? client,
  })  : _database = database,
        _client = client ?? supabase.Supabase.instance.client;

  final AppDatabase _database;
  final supabase.SupabaseClient _client;

  Future<void> syncBankRules() async {
    if (!SupabaseConfig.isConfigured) return;
    final rows = await _client
        .from('bank_rules')
        .select('bank_key, locale, rules_json, version')
        .eq('is_active', true);
    for (final row in rows) {
      final data = row;
      final bankKey = data['bank_key'] as String;
      final locale = data['locale'] as String? ?? 'ar-SA';
      final version = data['version'] as int? ?? 1;
      final id = '$bankKey:$locale:$version';
      await _database.customInsert(
        '''
          INSERT OR REPLACE INTO parsing_rules(
            id, bank_key, locale, pattern, field, priority, version, is_active
          )
          VALUES (?, ?, ?, ?, 'remote_json', 0, ?, 1);
        ''',
        variables: [
          Variable.withString(id),
          Variable.withString(bankKey),
          Variable.withString(locale),
          Variable.withString(jsonEncode(data['rules_json'])),
          Variable.withInt(version),
        ],
      );
    }
  }
}
