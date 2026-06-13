import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../../data/db/app_database.dart';
import '../../engine/models/transaction_source.dart';
import '../../engine/parser/bank_profile.dart';
import 'supabase_config.dart';

class RulesClient {
  RulesClient({
    required AppDatabase database,
    supabase.SupabaseClient? client,
  })  : _database = database,
        _client = client;

  final AppDatabase _database;
  final supabase.SupabaseClient? _client;

  Future<void> syncBankRules() async {
    if (!SupabaseConfig.isConfigured) return;
    final client = _client ?? supabase.Supabase.instance.client;
    final rows = await client
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

  Future<List<BankProfile>> localBankProfiles({String locale = 'ar-SA'}) async {
    final rows = await _database.customSelect(
      '''
        SELECT bank_key, locale, pattern, version
        FROM parsing_rules
        WHERE field = 'remote_json'
          AND is_active = 1
          AND (locale = ? OR locale = 'default')
        ORDER BY version DESC, priority DESC;
      ''',
      variables: [Variable.withString(locale)],
    ).get();

    final seen = <String>{};
    final profiles = <BankProfile>[];
    for (final row in rows) {
      final bankKey = row.read<String>('bank_key');
      if (!seen.add(bankKey)) continue;
      final profile = _profileFromJson(
        bankKey: bankKey,
        rulesJson: row.read<String>('pattern'),
      );
      if (profile != null) profiles.add(profile);
    }
    return profiles;
  }

  BankProfile? _profileFromJson({
    required String bankKey,
    required String rulesJson,
  }) {
    final decoded = jsonDecode(rulesJson);
    if (decoded is! Map<String, dynamic>) return null;

    final keywordsValue = decoded['keywords'];
    final keywords = keywordsValue is List
        ? keywordsValue.whereType<String>().map((item) => item.trim()).where(
              (item) => item.isNotEmpty,
            )
        : const Iterable<String>.empty();
    final keywordList = keywords.toList(growable: false);
    if (keywordList.isEmpty) return null;

    final displayName = (decoded['displayName'] ??
            decoded['display_name'] ??
            decoded['name'] ??
            bankKey)
        .toString();
    final source = _sourceFromJson(decoded['source']?.toString());
    return BankProfile(
      bankKey: bankKey,
      displayName: displayName,
      keywords: keywordList,
      defaultSource: source,
    );
  }

  TransactionSource _sourceFromJson(String? value) {
    switch (value?.toLowerCase().trim()) {
      case 'card':
        return TransactionSource.card;
      case 'wallet':
        return TransactionSource.wallet;
      case 'unknown':
        return TransactionSource.unknown;
      case 'bank':
      default:
        return TransactionSource.bank;
    }
  }
}
