import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../../data/catalog/catalog_daos.dart';
import '../../data/db/app_database.dart';
import '../../engine/models/transaction_source.dart';
import '../../engine/models/transaction_type.dart';
import '../../engine/parser/bank_profile.dart';

class RulesClient {
  RulesClient({
    required AppDatabase database,
    supabase.SupabaseClient? client,
  })  : _database = database,
        _client = client;

  final AppDatabase _database;
  // Kept for constructor compatibility. Catalog sync owns all network reads.
  // RulesClient only reads the local Drift cache.
  // ignore: unused_field
  final supabase.SupabaseClient? _client;
  final Map<String, RegExp> _regexCache = {};

  @Deprecated('Use CatalogSyncService; RulesClient must not read the network.')
  Future<void> syncBankRules() async {
    return;
  }

  Future<List<BankProfile>> localBankProfiles({
    String locale = 'ar-SA',
    String? senderId,
  }) async {
    final senderBank = senderId == null
        ? null
        : await RemoteBanksDao(_database).getBankBySender(senderId);

    final rows = await _database.customSelect(
      '''
        SELECT
          b.id AS bank_id,
          b.name_ar,
          b.name_en,
          b.short_code,
          b.country_code,
          b.sms_senders,
          b.supported_currencies,
          p.id AS parser_id,
          p.sender_pattern,
          p.message_pattern,
          p.transaction_type,
          p.language,
          p.priority,
          p.extracted_fields
        FROM remote_banks b
        LEFT JOIN remote_parsers p
          ON p.bank_id = b.id
          AND p.is_active = 1
          AND p.is_deleted = 0
        WHERE b.is_active = 1
          AND b.is_deleted = 0
          AND (? IS NULL OR b.id = ?)
        ORDER BY b.sort_order ASC, p.priority DESC;
      ''',
      variables: [
        senderBank == null
            ? const Variable<String>(null)
            : Variable.withString(senderBank.id),
        senderBank == null
            ? const Variable<String>(null)
            : Variable.withString(senderBank.id),
      ],
    ).get();

    final grouped = <String, _RemoteBankProfileDraft>{};
    for (final row in rows) {
      final bankId = row.read<String>('bank_id');
      final draft = grouped.putIfAbsent(
        bankId,
        () => _RemoteBankProfileDraft(
          bankKey: row.read<String>('short_code'),
          displayName: row.read<String>('name_ar'),
          country: row.read<String>('country_code'),
          senderIds: _jsonStringList(row.read<String>('sms_senders')).toSet(),
          keywords: {
            row.read<String>('short_code'),
            row.read<String>('name_ar'),
            row.read<String>('name_en'),
          },
          defaultSource: _sourceForBank(row.read<String>('short_code')),
        ),
      );

      final parserId = row.readNullable<String>('parser_id');
      if (parserId == null) continue;
      final senderPattern = row.read<String>('sender_pattern');
      final messagePattern = row.read<String>('message_pattern');
      if (_cachedRegex('$parserId:sender', senderPattern) == null ||
          _cachedRegex('$parserId:message', messagePattern) == null) {
        continue;
      }

      draft.applyParser(
        transactionType: row.read<String>('transaction_type'),
        extractedFields: _jsonObjectMap(row.read<String>('extracted_fields')),
      );
    }
    final profiles = grouped.values.map((draft) => draft.toProfile()).toList();
    if (profiles.isEmpty) {
      return _legacyLocalBankProfiles(locale: locale);
    }
    return profiles;
  }

  Future<BankProfile?> profileForSender(String senderId) async {
    final bank = await RemoteBanksDao(_database).getBankBySender(senderId);
    if (bank == null) return null;
    final profiles = await localBankProfiles(senderId: senderId);
    for (final profile in profiles) {
      if (profile.bankKey == bank.shortCode) return profile;
    }
    return null;
  }

  RegExp? _cachedRegex(String key, String pattern) {
    final cached = _regexCache[key];
    if (cached != null) return cached;
    try {
      final regex = RegExp(pattern, caseSensitive: false);
      _regexCache[key] = regex;
      return regex;
    } on FormatException {
      return null;
    }
  }

  Future<List<BankProfile>> _legacyLocalBankProfiles({
    required String locale,
  }) async {
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
    final Object? decoded;
    try {
      decoded = jsonDecode(rulesJson);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;

    final keywordsValue = decoded['keywords'];
    final keywords = keywordsValue is List
        ? keywordsValue.whereType<String>().map((item) => item.trim()).where(
              (item) => item.isNotEmpty,
            )
        : const Iterable<String>.empty();
    final keywordList = keywords.toList(growable: false);
    final senderIds =
        _stringList(decoded['senderIds'] ?? decoded['sender_ids']);
    if (keywordList.isEmpty && senderIds.isEmpty) return null;

    final displayName = (decoded['displayName'] ??
            decoded['display_name'] ??
            decoded['name'] ??
            bankKey)
        .toString();
    final source = _sourceFromJson(decoded['source']?.toString());
    return BankProfile(
      bankKey: bankKey,
      displayName: displayName,
      country: decoded['country']?.toString(),
      locale: decoded['locale']?.toString(),
      senderIds: senderIds,
      keywords: keywordList,
      currencyAliases:
          _stringMap(decoded['currencyAliases'] ?? decoded['currency_aliases']),
      ignoreRules:
          _stringList(decoded['ignoreRules'] ?? decoded['ignore_rules']),
      typeRules: _typeRules(decoded['typeRules'] ?? decoded['type_rules']),
      amountRules:
          _stringList(decoded['amountRules'] ?? decoded['amount_rules']),
      balanceRules:
          _stringList(decoded['balanceRules'] ?? decoded['balance_rules']),
      merchantRules:
          _stringList(decoded['merchantRules'] ?? decoded['merchant_rules']),
      dateRules: _stringList(decoded['dateRules'] ?? decoded['date_rules']),
      version: int.tryParse(decoded['version']?.toString() ?? '') ?? 1,
      defaultSource: source,
    );
  }

  List<String> _stringList(Object? value) {
    if (value is! List) return const [];
    return value
        .whereType<String>()
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }

  List<String> _jsonStringList(String value) {
    final decoded = jsonDecode(value);
    if (decoded is! List) return const [];
    return decoded
        .map((item) => item.toString().trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }

  Map<String, Object?> _jsonObjectMap(String value) {
    final decoded = jsonDecode(value);
    if (decoded is! Map) return const {};
    return decoded.map((key, val) => MapEntry(key.toString(), val));
  }

  Map<String, String> _stringMap(Object? value) {
    if (value is! Map) return const {};
    return value.map((key, val) => MapEntry(key.toString(), val.toString()));
  }

  Map<TransactionType, List<String>> _typeRules(Object? value) {
    if (value is! Map) return const {};
    final rules = <TransactionType, List<String>>{};
    for (final entry in value.entries) {
      final type = _typeFromJson(entry.key.toString());
      if (type == null) continue;
      final terms = _stringList(entry.value);
      if (terms.isNotEmpty) rules[type] = terms;
    }
    return rules;
  }

  TransactionType? _typeFromJson(String value) {
    switch (value.toLowerCase().trim()) {
      case 'payment':
      case 'purchase':
      case 'debit':
        return TransactionType.payment;
      case 'withdrawal':
      case 'atm':
        return TransactionType.withdrawal;
      case 'transfer':
        return TransactionType.transfer;
      case 'refund':
      case 'reversal':
        return TransactionType.refund;
      case 'income':
      case 'deposit':
      case 'salary':
        return TransactionType.income;
      case 'unknown':
        return TransactionType.unknown;
      default:
        return null;
    }
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

  TransactionSource _sourceForBank(String shortCode) {
    final normalized = shortCode.toLowerCase();
    if (normalized.contains('cash') ||
        normalized.contains('wallet') ||
        normalized.contains('pay') ||
        normalized.contains('fawry')) {
      return TransactionSource.wallet;
    }
    return TransactionSource.bank;
  }
}

class _RemoteBankProfileDraft {
  _RemoteBankProfileDraft({
    required this.bankKey,
    required this.displayName,
    required this.country,
    required this.senderIds,
    required this.keywords,
    required this.defaultSource,
  });

  final String bankKey;
  final String displayName;
  final String country;
  final Set<String> senderIds;
  final Set<String> keywords;
  final TransactionSource defaultSource;
  final Map<TransactionType, Set<String>> typeRules = {};
  final Set<String> amountRules = {};
  final Set<String> balanceRules = {};
  final Set<String> merchantRules = {};
  final Set<String> dateRules = {};

  void applyParser({
    required String transactionType,
    required Map<String, Object?> extractedFields,
  }) {
    final type = _typeFromParser(transactionType);
    typeRules.putIfAbsent(type, () => <String>{}).addAll(
          switch (type) {
            TransactionType.payment => const [
                'debit',
                'purchase',
                'خصم',
                'شراء'
              ],
            TransactionType.withdrawal => const ['withdrawal', 'atm', 'سحب'],
            TransactionType.transfer => const ['transfer', 'تحويل'],
            TransactionType.refund => const ['refund', 'reversal', 'استرداد'],
            TransactionType.income => const [
                'credit',
                'salary',
                'إيداع',
                'راتب'
              ],
            TransactionType.creditCardPayment => const ['سداد', 'تأكيد السداد'],
            TransactionType.governmentPayment => const ['مدفوعات', 'سداد'],
            TransactionType.unknown => const <String>[],
          },
        );
    if (extractedFields.containsKey('amount')) {
      amountRules.addAll(const ['amount', 'مبلغ', 'قيمة']);
    }
    if (extractedFields.containsKey('balance')) {
      balanceRules.addAll(const ['balance', 'available', 'الرصيد', 'المتاح']);
    }
    if (extractedFields.containsKey('merchant')) {
      merchantRules.addAll(const ['merchant', 'لدى', 'At']);
    }
    if (extractedFields.containsKey('date')) {
      dateRules.addAll(const ['date', 'في', 'on']);
    }
  }

  BankProfile toProfile() {
    return BankProfile(
      bankKey: bankKey,
      displayName: displayName,
      country: country,
      senderIds: senderIds.toList(growable: false),
      keywords: keywords.toList(growable: false),
      typeRules: typeRules.map(
        (key, value) => MapEntry(key, value.toList(growable: false)),
      ),
      amountRules: amountRules.toList(growable: false),
      balanceRules: balanceRules.toList(growable: false),
      merchantRules: merchantRules.toList(growable: false),
      dateRules: dateRules.toList(growable: false),
      defaultSource: defaultSource,
    );
  }

  static TransactionType _typeFromParser(String value) {
    switch (value.toLowerCase().trim()) {
      case 'debit':
        return TransactionType.payment;
      case 'credit':
        return TransactionType.income;
      case 'balance_inquiry':
      default:
        return TransactionType.unknown;
    }
  }
}
