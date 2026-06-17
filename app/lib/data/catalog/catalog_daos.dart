import 'dart:convert';

import 'package:drift/drift.dart';

import '../db/app_database.dart';
import '../db/sql_value_codec.dart';

class CatalogCategories {
  CatalogCategories._();

  static const banks = 'banks';
  static const parsers = 'parsers';
  static const currencies = 'currencies';
  static const countries = 'countries';
  static const categories = 'categories';
  static const merchantKeywords = 'merchant_keywords';

  static const phase0 = <String>[
    banks,
    parsers,
    currencies,
    countries,
  ];

  static const syncable = <String>[
    banks,
    parsers,
    currencies,
    countries,
    categories,
    merchantKeywords,
  ];
}

class CatalogMetadata {
  const CatalogMetadata({
    required this.category,
    required this.serverVersion,
    required this.localVersion,
    required this.lastSyncedAt,
    required this.etag,
  });

  final String category;
  final int serverVersion;
  final int localVersion;
  final DateTime? lastSyncedAt;
  final String? etag;
}

class CatalogMetadataDao {
  CatalogMetadataDao(this._db);

  final AppDatabase _db;

  Future<CatalogMetadata?> getVersion(String category) async {
    final row = await _db.customSelect(
      '''
        SELECT category, server_version, local_version, last_synced_at, etag
        FROM catalog_metadata
        WHERE category = ?
        LIMIT 1;
      ''',
      variables: [Variable.withString(category)],
    ).getSingleOrNull();
    if (row == null) return null;
    return _metadataFromRow(row);
  }

  Future<void> upsertVersion(
    String category,
    int serverV,
    int localV,
  ) async {
    await _db.customInsert(
      '''
        INSERT INTO catalog_metadata(category, server_version, local_version, last_synced_at, etag)
        VALUES (?, ?, ?, NULL, NULL)
        ON CONFLICT(category) DO UPDATE SET
          server_version = excluded.server_version,
          local_version = excluded.local_version;
      ''',
      variables: [
        Variable.withString(category),
        Variable.withInt(serverV),
        Variable.withInt(localV),
      ],
    );
  }

  Future<void> setLastSynced(String category, DateTime value) async {
    await _db.customInsert(
      '''
        INSERT INTO catalog_metadata(category, server_version, local_version, last_synced_at, etag)
        VALUES (?, 0, 0, ?, NULL)
        ON CONFLICT(category) DO UPDATE SET
          last_synced_at = excluded.last_synced_at;
      ''',
      variables: [
        Variable.withString(category),
        Variable.withString(dateTimeToSql(value)),
      ],
    );
  }

  CatalogMetadata _metadataFromRow(QueryRow row) {
    final synced = row.readNullable<String>('last_synced_at');
    return CatalogMetadata(
      category: row.read<String>('category'),
      serverVersion: row.read<int>('server_version'),
      localVersion: row.read<int>('local_version'),
      lastSyncedAt: synced == null ? null : dateTimeFromSql(synced),
      etag: row.readNullable<String>('etag'),
    );
  }
}

class RemoteBank {
  const RemoteBank({
    required this.id,
    required this.nameAr,
    required this.nameEn,
    required this.shortCode,
    required this.logoUrl,
    required this.countryCode,
    required this.smsSenders,
    required this.supportedCurrencies,
    required this.colorHex,
    required this.isActive,
    required this.sortOrder,
    required this.isDeleted,
    required this.updatedAt,
  });

  final String id;
  final String nameAr;
  final String nameEn;
  final String shortCode;
  final String? logoUrl;
  final String countryCode;
  final List<String> smsSenders;
  final List<String> supportedCurrencies;
  final String? colorHex;
  final bool isActive;
  final int sortOrder;
  final bool isDeleted;
  final DateTime updatedAt;

  static RemoteBank fromJson(Map<String, Object?> json) {
    return RemoteBank(
      id: json['id'].toString(),
      nameAr: json['name_ar'].toString(),
      nameEn: json['name_en'].toString(),
      shortCode: json['short_code'].toString(),
      logoUrl: _optionalString(json['logo_url']),
      countryCode: json['country_code'].toString(),
      smsSenders: _stringList(json['sms_senders']),
      supportedCurrencies: _stringList(json['supported_currencies']),
      colorHex: _optionalString(json['color_hex']),
      isActive: json['is_active'] as bool? ?? true,
      sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
      isDeleted: json['is_deleted'] as bool? ?? false,
      updatedAt: _dateTimeFromJson(json['updated_at']),
    );
  }
}

class RemoteBanksDao {
  RemoteBanksDao(this._db);

  final AppDatabase _db;

  Future<void> upsertAll(List<RemoteBank> banks) async {
    await _db.transaction(() async {
      for (final bank in banks) {
        await _db.customInsert(
          '''
            INSERT INTO remote_banks(
              id, name_ar, name_en, short_code, logo_url, country_code,
              sms_senders, supported_currencies, color_hex, is_active,
              sort_order, is_deleted, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              name_ar = excluded.name_ar,
              name_en = excluded.name_en,
              short_code = excluded.short_code,
              logo_url = excluded.logo_url,
              country_code = excluded.country_code,
              sms_senders = excluded.sms_senders,
              supported_currencies = excluded.supported_currencies,
              color_hex = excluded.color_hex,
              is_active = excluded.is_active,
              sort_order = excluded.sort_order,
              is_deleted = excluded.is_deleted,
              updated_at = excluded.updated_at;
          ''',
          variables: [
            Variable.withString(bank.id),
            Variable.withString(bank.nameAr),
            Variable.withString(bank.nameEn),
            Variable.withString(bank.shortCode),
            _nullableString(bank.logoUrl),
            Variable.withString(bank.countryCode),
            Variable.withString(jsonEncode(bank.smsSenders)),
            Variable.withString(jsonEncode(bank.supportedCurrencies)),
            _nullableString(bank.colorHex),
            Variable.withInt(boolToSql(bank.isActive)),
            Variable.withInt(bank.sortOrder),
            Variable.withInt(boolToSql(bank.isDeleted)),
            Variable.withString(dateTimeToSql(bank.updatedAt)),
          ],
        );
      }
    });
  }

  Future<void> markDeleted(List<String> ids) async {
    await _db.transaction(() async {
      for (final id in ids) {
        await _db.customUpdate(
          '''
            UPDATE remote_banks
            SET is_deleted = 1, is_active = 0, updated_at = ?
            WHERE id = ?;
          ''',
          variables: [
            Variable.withString(dateTimeToSql(DateTime.now().toUtc())),
            Variable.withString(id),
          ],
        );
      }
    });
  }

  Future<List<RemoteBank>> getActiveBanks(String countryCode) async {
    final rows = await _db.customSelect(
      '''
        SELECT *
        FROM remote_banks
        WHERE country_code = ?
          AND is_active = 1
          AND is_deleted = 0
        ORDER BY sort_order ASC, name_ar ASC;
      ''',
      variables: [Variable.withString(countryCode)],
    ).get();
    return rows.map(_bankFromRow).toList();
  }

  Future<RemoteBank?> getBankBySender(String sender) async {
    final normalized = sender.trim().toLowerCase();
    if (normalized.isEmpty) return null;
    final rows = await _db.customSelect(
      '''
        SELECT *
        FROM remote_banks
        WHERE is_active = 1
          AND is_deleted = 0
        ORDER BY sort_order ASC, name_ar ASC;
      ''',
    ).get();
    for (final row in rows) {
      final bank = _bankFromRow(row);
      final matched = bank.smsSenders.any(
        (candidate) => normalized.contains(candidate.toLowerCase()),
      );
      if (matched) return bank;
    }
    return null;
  }

  RemoteBank _bankFromRow(QueryRow row) {
    return RemoteBank(
      id: row.read<String>('id'),
      nameAr: row.read<String>('name_ar'),
      nameEn: row.read<String>('name_en'),
      shortCode: row.read<String>('short_code'),
      logoUrl: row.readNullable<String>('logo_url'),
      countryCode: row.read<String>('country_code'),
      smsSenders: _jsonStringList(row.read<String>('sms_senders')),
      supportedCurrencies:
          _jsonStringList(row.read<String>('supported_currencies')),
      colorHex: row.readNullable<String>('color_hex'),
      isActive: sqlToBool(row.read<int>('is_active')),
      sortOrder: row.read<int>('sort_order'),
      isDeleted: sqlToBool(row.read<int>('is_deleted')),
      updatedAt: dateTimeFromSql(row.read<String>('updated_at')),
    );
  }
}

class RemoteParser {
  const RemoteParser({
    required this.id,
    required this.bankId,
    required this.senderPattern,
    required this.messagePattern,
    required this.transactionType,
    required this.language,
    required this.priority,
    required this.extractedFields,
    required this.isActive,
    required this.isDeleted,
    required this.updatedAt,
  });

  final String id;
  final String bankId;
  final String senderPattern;
  final String messagePattern;
  final String transactionType;
  final String language;
  final int priority;
  final Map<String, Object?> extractedFields;
  final bool isActive;
  final bool isDeleted;
  final DateTime updatedAt;

  static RemoteParser fromJson(Map<String, Object?> json) {
    return RemoteParser(
      id: json['id'].toString(),
      bankId: json['bank_id'].toString(),
      senderPattern: json['sender_pattern'].toString(),
      messagePattern: json['message_pattern'].toString(),
      transactionType: json['transaction_type'].toString(),
      language: json['language'].toString(),
      priority: (json['priority'] as num?)?.toInt() ?? 0,
      extractedFields: _objectMap(json['extracted_fields']),
      isActive: json['is_active'] as bool? ?? true,
      isDeleted: json['is_deleted'] as bool? ?? false,
      updatedAt: _dateTimeFromJson(json['updated_at']),
    );
  }
}

class RemoteParsersDao {
  RemoteParsersDao(this._db);

  final AppDatabase _db;

  Future<void> upsertAll(List<RemoteParser> parsers) async {
    await _db.transaction(() async {
      for (final parser in parsers) {
        await _db.customInsert(
          '''
            INSERT INTO remote_parsers(
              id, bank_id, sender_pattern, message_pattern, transaction_type,
              language, priority, extracted_fields, is_active, is_deleted,
              updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              bank_id = excluded.bank_id,
              sender_pattern = excluded.sender_pattern,
              message_pattern = excluded.message_pattern,
              transaction_type = excluded.transaction_type,
              language = excluded.language,
              priority = excluded.priority,
              extracted_fields = excluded.extracted_fields,
              is_active = excluded.is_active,
              is_deleted = excluded.is_deleted,
              updated_at = excluded.updated_at;
          ''',
          variables: [
            Variable.withString(parser.id),
            Variable.withString(parser.bankId),
            Variable.withString(parser.senderPattern),
            Variable.withString(parser.messagePattern),
            Variable.withString(parser.transactionType),
            Variable.withString(parser.language),
            Variable.withInt(parser.priority),
            Variable.withString(jsonEncode(parser.extractedFields)),
            Variable.withInt(boolToSql(parser.isActive)),
            Variable.withInt(boolToSql(parser.isDeleted)),
            Variable.withString(dateTimeToSql(parser.updatedAt)),
          ],
        );
      }
    });
  }

  Future<void> markDeleted(List<String> ids) async {
    await _db.transaction(() async {
      for (final id in ids) {
        await _db.customUpdate(
          '''
            UPDATE remote_parsers
            SET is_deleted = 1, is_active = 0, updated_at = ?
            WHERE id = ?;
          ''',
          variables: [
            Variable.withString(dateTimeToSql(DateTime.now().toUtc())),
            Variable.withString(id),
          ],
        );
      }
    });
  }

  Future<List<RemoteParser>> getActiveParsersByBankId(String bankId) async {
    final rows = await _db.customSelect(
      '''
        SELECT *
        FROM remote_parsers
        WHERE bank_id = ?
          AND is_active = 1
          AND is_deleted = 0
        ORDER BY priority DESC, updated_at DESC;
      ''',
      variables: [Variable.withString(bankId)],
    ).get();
    return rows.map(_parserFromRow).toList();
  }

  Future<List<RemoteParser>> getAllActiveParsers() async {
    final rows = await _db.customSelect(
      '''
        SELECT *
        FROM remote_parsers
        WHERE is_active = 1
          AND is_deleted = 0
        ORDER BY priority DESC, updated_at DESC;
      ''',
    ).get();
    return rows.map(_parserFromRow).toList();
  }

  RemoteParser _parserFromRow(QueryRow row) {
    return RemoteParser(
      id: row.read<String>('id'),
      bankId: row.read<String>('bank_id'),
      senderPattern: row.read<String>('sender_pattern'),
      messagePattern: row.read<String>('message_pattern'),
      transactionType: row.read<String>('transaction_type'),
      language: row.read<String>('language'),
      priority: row.read<int>('priority'),
      extractedFields: _jsonObjectMap(row.read<String>('extracted_fields')),
      isActive: sqlToBool(row.read<int>('is_active')),
      isDeleted: sqlToBool(row.read<int>('is_deleted')),
      updatedAt: dateTimeFromSql(row.read<String>('updated_at')),
    );
  }
}

class RemoteCurrency {
  const RemoteCurrency({
    required this.code,
    required this.nameAr,
    required this.nameEn,
    required this.symbol,
    required this.decimalPlaces,
    required this.countryCodes,
    required this.isActive,
    required this.isDeleted,
    required this.updatedAt,
  });

  final String code;
  final String nameAr;
  final String nameEn;
  final String symbol;
  final int decimalPlaces;
  final List<String> countryCodes;
  final bool isActive;
  final bool isDeleted;
  final DateTime updatedAt;

  static RemoteCurrency fromJson(Map<String, Object?> json) {
    return RemoteCurrency(
      code: json['code'].toString(),
      nameAr: json['name_ar'].toString(),
      nameEn: json['name_en'].toString(),
      symbol: json['symbol'].toString(),
      decimalPlaces: (json['decimal_places'] as num?)?.toInt() ?? 2,
      countryCodes: _stringList(json['country_codes']),
      isActive: json['is_active'] as bool? ?? true,
      isDeleted: json['is_deleted'] as bool? ?? false,
      updatedAt: _dateTimeFromJson(json['updated_at']),
    );
  }
}

class RemoteCurrenciesDao {
  RemoteCurrenciesDao(this._db);

  final AppDatabase _db;

  Future<void> upsertAll(List<RemoteCurrency> currencies) async {
    await _db.transaction(() async {
      for (final currency in currencies) {
        await _db.customInsert(
          '''
            INSERT INTO remote_currencies(
              code, name_ar, name_en, symbol, decimal_places, country_codes,
              is_active, is_deleted, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(code) DO UPDATE SET
              name_ar = excluded.name_ar,
              name_en = excluded.name_en,
              symbol = excluded.symbol,
              decimal_places = excluded.decimal_places,
              country_codes = excluded.country_codes,
              is_active = excluded.is_active,
              is_deleted = excluded.is_deleted,
              updated_at = excluded.updated_at;
          ''',
          variables: [
            Variable.withString(currency.code),
            Variable.withString(currency.nameAr),
            Variable.withString(currency.nameEn),
            Variable.withString(currency.symbol),
            Variable.withInt(currency.decimalPlaces),
            Variable.withString(jsonEncode(currency.countryCodes)),
            Variable.withInt(boolToSql(currency.isActive)),
            Variable.withInt(boolToSql(currency.isDeleted)),
            Variable.withString(dateTimeToSql(currency.updatedAt)),
          ],
        );
      }
    });
  }

  Future<List<RemoteCurrency>> getActiveCurrencies() async {
    final rows = await _db.customSelect(
      '''
        SELECT *
        FROM remote_currencies
        WHERE is_active = 1
          AND is_deleted = 0
        ORDER BY code ASC;
      ''',
    ).get();
    return rows.map(_currencyFromRow).toList();
  }

  Future<void> markDeleted(List<String> codes) async {
    await _db.transaction(() async {
      for (final code in codes) {
        await _db.customUpdate(
          '''
            UPDATE remote_currencies
            SET is_deleted = 1, is_active = 0, updated_at = ?
            WHERE code = ?;
          ''',
          variables: [
            Variable.withString(dateTimeToSql(DateTime.now().toUtc())),
            Variable.withString(code),
          ],
        );
      }
    });
  }

  Future<List<RemoteCurrency>> getCurrenciesForCountry(
    String countryCode,
  ) async {
    final normalized = countryCode.trim().toUpperCase();
    final currencies = await getActiveCurrencies();
    return currencies
        .where((currency) => currency.countryCodes.contains(normalized))
        .toList(growable: false);
  }

  RemoteCurrency _currencyFromRow(QueryRow row) {
    return RemoteCurrency(
      code: row.read<String>('code'),
      nameAr: row.read<String>('name_ar'),
      nameEn: row.read<String>('name_en'),
      symbol: row.read<String>('symbol'),
      decimalPlaces: row.read<int>('decimal_places'),
      countryCodes: _jsonStringList(row.read<String>('country_codes')),
      isActive: sqlToBool(row.read<int>('is_active')),
      isDeleted: sqlToBool(row.read<int>('is_deleted')),
      updatedAt: dateTimeFromSql(row.read<String>('updated_at')),
    );
  }
}

class RemoteCountry {
  const RemoteCountry({
    required this.code,
    required this.nameAr,
    required this.nameEn,
    required this.flagEmoji,
    required this.phonePrefix,
    required this.isSupported,
    required this.isActive,
    required this.isDeleted,
    required this.updatedAt,
  });

  final String code;
  final String nameAr;
  final String nameEn;
  final String flagEmoji;
  final String phonePrefix;
  final bool isSupported;
  final bool isActive;
  final bool isDeleted;
  final DateTime updatedAt;

  static RemoteCountry fromJson(Map<String, Object?> json) {
    return RemoteCountry(
      code: json['code'].toString(),
      nameAr: json['name_ar'].toString(),
      nameEn: json['name_en'].toString(),
      flagEmoji: json['flag_emoji'].toString(),
      phonePrefix: json['phone_prefix'].toString(),
      isSupported: json['is_supported'] as bool? ?? false,
      isActive: json['is_active'] as bool? ?? true,
      isDeleted: json['is_deleted'] as bool? ?? false,
      updatedAt: _dateTimeFromJson(json['updated_at']),
    );
  }
}

class RemoteCountriesDao {
  RemoteCountriesDao(this._db);

  final AppDatabase _db;

  Future<void> upsertAll(List<RemoteCountry> countries) async {
    await _db.transaction(() async {
      for (final country in countries) {
        await _db.customInsert(
          '''
            INSERT INTO remote_countries(
              code, name_ar, name_en, flag_emoji, phone_prefix, is_supported,
              is_active, is_deleted, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(code) DO UPDATE SET
              name_ar = excluded.name_ar,
              name_en = excluded.name_en,
              flag_emoji = excluded.flag_emoji,
              phone_prefix = excluded.phone_prefix,
              is_supported = excluded.is_supported,
              is_active = excluded.is_active,
              is_deleted = excluded.is_deleted,
              updated_at = excluded.updated_at;
          ''',
          variables: [
            Variable.withString(country.code),
            Variable.withString(country.nameAr),
            Variable.withString(country.nameEn),
            Variable.withString(country.flagEmoji),
            Variable.withString(country.phonePrefix),
            Variable.withInt(boolToSql(country.isSupported)),
            Variable.withInt(boolToSql(country.isActive)),
            Variable.withInt(boolToSql(country.isDeleted)),
            Variable.withString(dateTimeToSql(country.updatedAt)),
          ],
        );
      }
    });
  }

  Future<List<RemoteCountry>> getSupportedCountries() async {
    final rows = await _db.customSelect(
      '''
        SELECT *
        FROM remote_countries
        WHERE is_supported = 1
          AND is_active = 1
          AND is_deleted = 0
        ORDER BY name_ar ASC;
      ''',
    ).get();
    return rows.map(_countryFromRow).toList();
  }

  Future<void> markDeleted(List<String> codes) async {
    await _db.transaction(() async {
      for (final code in codes) {
        await _db.customUpdate(
          '''
            UPDATE remote_countries
            SET is_deleted = 1, is_active = 0, updated_at = ?
            WHERE code = ?;
          ''',
          variables: [
            Variable.withString(dateTimeToSql(DateTime.now().toUtc())),
            Variable.withString(code),
          ],
        );
      }
    });
  }

  Future<RemoteCountry?> getByCode(String code) async {
    final row = await _db.customSelect(
      '''
        SELECT *
        FROM remote_countries
        WHERE code = ?
          AND is_active = 1
          AND is_deleted = 0
        LIMIT 1;
      ''',
      variables: [Variable.withString(code.trim().toUpperCase())],
    ).getSingleOrNull();
    return row == null ? null : _countryFromRow(row);
  }

  RemoteCountry _countryFromRow(QueryRow row) {
    return RemoteCountry(
      code: row.read<String>('code'),
      nameAr: row.read<String>('name_ar'),
      nameEn: row.read<String>('name_en'),
      flagEmoji: row.read<String>('flag_emoji'),
      phonePrefix: row.read<String>('phone_prefix'),
      isSupported: sqlToBool(row.read<int>('is_supported')),
      isActive: sqlToBool(row.read<int>('is_active')),
      isDeleted: sqlToBool(row.read<int>('is_deleted')),
      updatedAt: dateTimeFromSql(row.read<String>('updated_at')),
    );
  }
}

class RemoteCategory {
  const RemoteCategory({
    required this.id,
    required this.key,
    required this.nameAr,
    required this.nameEn,
    required this.icon,
    required this.colorHex,
    required this.parentKey,
    required this.type,
    required this.sortOrder,
    required this.isSystem,
    required this.isActive,
    required this.isDeleted,
    required this.updatedAt,
  });

  final String id;
  final String key;
  final String nameAr;
  final String nameEn;
  final String icon;
  final String colorHex;
  final String? parentKey;
  final String type;
  final int sortOrder;
  final bool isSystem;
  final bool isActive;
  final bool isDeleted;
  final DateTime updatedAt;

  static RemoteCategory fromJson(Map<String, Object?> json) {
    return RemoteCategory(
      id: json['id'].toString(),
      key: json['key'].toString(),
      nameAr: json['name_ar'].toString(),
      nameEn: json['name_en'].toString(),
      icon: json['icon'].toString(),
      colorHex: json['color_hex'].toString(),
      parentKey: _optionalString(json['parent_key']),
      type: json['type'].toString(),
      sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
      isSystem: json['is_system'] as bool? ?? false,
      isActive: json['is_active'] as bool? ?? true,
      isDeleted: json['is_deleted'] as bool? ?? false,
      updatedAt: _dateTimeFromJson(json['updated_at']),
    );
  }
}

class RemoteCategoriesDao {
  RemoteCategoriesDao(this._db);

  final AppDatabase _db;

  Future<void> upsertAll(List<RemoteCategory> categories) async {
    await _db.transaction(() async {
      for (final category in categories) {
        await _db.customInsert(
          '''
            INSERT INTO remote_categories(
              id, key, name_ar, name_en, icon, color_hex, parent_key, type,
              sort_order, is_system, is_active, is_deleted, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              key = excluded.key,
              name_ar = excluded.name_ar,
              name_en = excluded.name_en,
              icon = excluded.icon,
              color_hex = excluded.color_hex,
              parent_key = excluded.parent_key,
              type = excluded.type,
              sort_order = excluded.sort_order,
              is_system = excluded.is_system,
              is_active = excluded.is_active,
              is_deleted = excluded.is_deleted,
              updated_at = excluded.updated_at;
          ''',
          variables: [
            Variable.withString(category.id),
            Variable.withString(category.key),
            Variable.withString(category.nameAr),
            Variable.withString(category.nameEn),
            Variable.withString(category.icon),
            Variable.withString(category.colorHex),
            _nullableString(category.parentKey),
            Variable.withString(category.type),
            Variable.withInt(category.sortOrder),
            Variable.withInt(boolToSql(category.isSystem)),
            Variable.withInt(boolToSql(category.isActive)),
            Variable.withInt(boolToSql(category.isDeleted)),
            Variable.withString(dateTimeToSql(category.updatedAt)),
          ],
        );
      }
    });
  }

  Future<void> markDeleted(List<String> ids) async {
    await _db.transaction(() async {
      for (final id in ids) {
        await _db.customUpdate(
          '''
            UPDATE remote_categories
            SET is_deleted = 1, is_active = 0, updated_at = ?
            WHERE id = ?;
          ''',
          variables: [
            Variable.withString(dateTimeToSql(DateTime.now().toUtc())),
            Variable.withString(id),
          ],
        );
      }
    });
  }

  Future<RemoteCategory?> getByKey(String key) async {
    final row = await _db.customSelect(
      '''
        SELECT *
        FROM remote_categories
        WHERE key = ?
          AND is_active = 1
          AND is_deleted = 0
        LIMIT 1;
      ''',
      variables: [Variable.withString(key)],
    ).getSingleOrNull();
    return row == null ? null : _categoryFromRow(row);
  }

  Future<List<RemoteCategory>> getActiveCategories() async {
    final rows = await _db.customSelect(
      '''
        SELECT *
        FROM remote_categories
        WHERE is_active = 1
          AND is_deleted = 0
        ORDER BY sort_order ASC, name_ar ASC;
      ''',
    ).get();
    return rows.map(_categoryFromRow).toList();
  }

  Future<List<RemoteCategory>> getSystemCategories() async {
    final rows = await _db.customSelect(
      '''
        SELECT *
        FROM remote_categories
        WHERE is_system = 1
          AND is_active = 1
          AND is_deleted = 0
        ORDER BY sort_order ASC, name_ar ASC;
      ''',
    ).get();
    return rows.map(_categoryFromRow).toList();
  }

  RemoteCategory _categoryFromRow(QueryRow row) {
    return RemoteCategory(
      id: row.read<String>('id'),
      key: row.read<String>('key'),
      nameAr: row.read<String>('name_ar'),
      nameEn: row.read<String>('name_en'),
      icon: row.read<String>('icon'),
      colorHex: row.read<String>('color_hex'),
      parentKey: row.readNullable<String>('parent_key'),
      type: row.read<String>('type'),
      sortOrder: row.read<int>('sort_order'),
      isSystem: sqlToBool(row.read<int>('is_system')),
      isActive: sqlToBool(row.read<int>('is_active')),
      isDeleted: sqlToBool(row.read<int>('is_deleted')),
      updatedAt: dateTimeFromSql(row.read<String>('updated_at')),
    );
  }
}

class RemoteMerchantKeyword {
  const RemoteMerchantKeyword({
    required this.id,
    required this.keyword,
    required this.categoryKey,
    required this.language,
    required this.countryCode,
    required this.priority,
    required this.isActive,
    required this.isDeleted,
    required this.updatedAt,
  });

  final String id;
  final String keyword;
  final String categoryKey;
  final String language;
  final String countryCode;
  final int priority;
  final bool isActive;
  final bool isDeleted;
  final String updatedAt;

  static RemoteMerchantKeyword fromJson(Map<String, Object?> json) {
    return RemoteMerchantKeyword(
      id: json['id'] as String,
      keyword: json['keyword'] as String,
      categoryKey: json['category_key'] as String,
      language: (json['language'] as String?) ?? 'any',
      countryCode: (json['country_code'] as String?) ?? 'ALL',
      priority: (json['priority'] as num?)?.toInt() ?? 0,
      isActive: _boolFromJson(json['is_active'], defaultValue: true),
      isDeleted: _boolFromJson(json['is_deleted']),
      updatedAt: json['updated_at'] as String,
    );
  }
}

class RemoteMerchantKeywordsDao {
  const RemoteMerchantKeywordsDao(this._db);

  final AppDatabase _db;

  Future<void> upsertAll(List<RemoteMerchantKeyword> keywords) async {
    for (final kw in keywords) {
      await _db.customInsert(
        '''
          INSERT INTO remote_merchant_keywords(
            id, keyword, category_key, language, country_code,
            priority, is_active, is_deleted, updated_at
          )
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET
            keyword = excluded.keyword,
            category_key = excluded.category_key,
            language = excluded.language,
            country_code = excluded.country_code,
            priority = excluded.priority,
            is_active = excluded.is_active,
            is_deleted = excluded.is_deleted,
            updated_at = excluded.updated_at;
        ''',
        variables: [
          Variable.withString(kw.id),
          Variable.withString(kw.keyword),
          Variable.withString(kw.categoryKey),
          Variable.withString(kw.language),
          Variable.withString(kw.countryCode),
          Variable.withInt(kw.priority),
          Variable.withInt(kw.isActive ? 1 : 0),
          Variable.withInt(kw.isDeleted ? 1 : 0),
          Variable.withString(kw.updatedAt),
        ],
      );
    }
  }

  Future<void> markDeleted(List<String> ids) async {
    for (final id in ids) {
      await _db.customUpdate(
        'UPDATE remote_merchant_keywords SET is_deleted = 1 WHERE id = ?;',
        variables: [Variable.withString(id)],
      );
    }
  }

  /// Returns active, non-deleted keywords for [countryCode] and 'ALL',
  /// ordered by priority descending (highest priority checked first).
  Future<List<RemoteMerchantKeyword>> getActiveForCountry(
      String countryCode) async {
    final rows = await _db.customSelect(
      '''
        SELECT * FROM remote_merchant_keywords
        WHERE is_active = 1
          AND is_deleted = 0
          AND (country_code = ? OR country_code = 'ALL')
        ORDER BY priority DESC;
      ''',
      variables: [Variable.withString(countryCode.toUpperCase())],
    ).get();
    return rows
        .map((r) => RemoteMerchantKeyword(
              id: r.read<String>('id'),
              keyword: r.read<String>('keyword'),
              categoryKey: r.read<String>('category_key'),
              language: r.read<String>('language'),
              countryCode: r.read<String>('country_code'),
              priority: r.read<int>('priority'),
              isActive: r.read<int>('is_active') != 0,
              isDeleted: r.read<int>('is_deleted') != 0,
              updatedAt: r.read<String>('updated_at'),
            ))
        .toList();
  }

  /// Returns all active, non-deleted keywords ordered by priority DESC.
  /// Used as the interim default until 4C wires a real country code from
  /// UserSettings — applying all keywords avoids silently excluding EG/Gulf
  /// markets whose currency codes don't map 1:1 to country codes.
  Future<List<RemoteMerchantKeyword>> getAll() async {
    final rows = await _db.customSelect(
      '''
        SELECT * FROM remote_merchant_keywords
        WHERE is_active = 1
          AND is_deleted = 0
        ORDER BY priority DESC;
      ''',
    ).get();
    return rows
        .map((r) => RemoteMerchantKeyword(
              id: r.read<String>('id'),
              keyword: r.read<String>('keyword'),
              categoryKey: r.read<String>('category_key'),
              language: r.read<String>('language'),
              countryCode: r.read<String>('country_code'),
              priority: r.read<int>('priority'),
              isActive: r.read<int>('is_active') != 0,
              isDeleted: r.read<int>('is_deleted') != 0,
              updatedAt: r.read<String>('updated_at'),
            ))
        .toList();
  }

  Future<bool> isEmpty() async {
    final rows = await _db
        .customSelect(
          'SELECT 1 FROM remote_merchant_keywords WHERE is_active = 1 AND is_deleted = 0 LIMIT 1;',
        )
        .get();
    return rows.isEmpty;
  }
}

class PendingMerchantFeedbackDao {
  const PendingMerchantFeedbackDao(this._db);

  final AppDatabase _db;

  Future<void> record(String normalizedKeyword) async {
    final now = DateTime.now().toUtc().toIso8601String();
    await _db.customInsert(
      '''
        INSERT INTO pending_merchant_feedback(normalized_keyword, seen_count, last_seen_at)
        VALUES (?, 1, ?)
        ON CONFLICT(normalized_keyword) DO UPDATE SET
          seen_count = seen_count + 1,
          last_seen_at = excluded.last_seen_at;
      ''',
      variables: [
        Variable.withString(normalizedKeyword),
        Variable.withString(now),
      ],
    );
  }

  Future<List<String>> drainAll() async {
    final rows = await _db
        .customSelect(
          'SELECT normalized_keyword FROM pending_merchant_feedback;',
        )
        .get();
    final keywords =
        rows.map((r) => r.read<String>('normalized_keyword')).toList();
    if (keywords.isNotEmpty) {
      await _db.customStatement('DELETE FROM pending_merchant_feedback;');
    }
    return keywords;
  }

  Future<int> count() async {
    final row = await _db
        .customSelect(
          'SELECT COUNT(*) AS total FROM pending_merchant_feedback;',
        )
        .getSingle();
    return row.read<int>('total');
  }
}

Variable<String> _nullableString(String? value) {
  return value == null
      ? const Variable<String>(null)
      : Variable.withString(value);
}

String? _optionalString(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

DateTime _dateTimeFromJson(Object? value) {
  final text = value?.toString();
  if (text == null || text.isEmpty) return DateTime.now().toUtc();
  return DateTime.parse(text).toUtc();
}

bool _boolFromJson(Object? value, {bool defaultValue = false}) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  return defaultValue;
}

List<String> _stringList(Object? value) {
  if (value is List) {
    return value.map((item) => item.toString()).toList(growable: false);
  }
  if (value is String) {
    return _jsonStringList(value);
  }
  return const [];
}

List<String> _jsonStringList(String value) {
  final decoded = jsonDecode(value);
  if (decoded is! List) return const [];
  return decoded.map((item) => item.toString()).toList(growable: false);
}

Map<String, Object?> _objectMap(Object? value) {
  if (value is Map) {
    return value.map((key, val) => MapEntry(key.toString(), val));
  }
  if (value is String) return _jsonObjectMap(value);
  return const {};
}

Map<String, Object?> _jsonObjectMap(String value) {
  final decoded = jsonDecode(value);
  if (decoded is! Map) return const {};
  return decoded.map((key, val) => MapEntry(key.toString(), val));
}

// ─────────────────────────────────────────────────────────
// Feature Flags
// ─────────────────────────────────────────────────────────

class RemoteFeatureFlag {
  const RemoteFeatureFlag({
    required this.key,
    required this.valueType,
    required this.value,
    required this.rolloutPercent,
    required this.targetCountries,
    required this.isActive,
    required this.syncedAt,
  });

  final String key;
  final String valueType;
  final String value;
  final int rolloutPercent;
  final List<String> targetCountries;
  final bool isActive;
  final DateTime syncedAt;

  static RemoteFeatureFlag fromJson(Map<String, Object?> json) {
    return RemoteFeatureFlag(
      key: json['key'].toString(),
      valueType: json['value_type'].toString(),
      value: json['value'].toString(),
      rolloutPercent: (json['rollout_percent'] as num?)?.toInt() ?? 100,
      targetCountries: _stringList(json['target_countries']),
      isActive: json['is_active'] as bool? ?? true,
      syncedAt: DateTime.now().toUtc(),
    );
  }
}

class RemoteFeatureFlagsDao {
  RemoteFeatureFlagsDao(this._db);

  final AppDatabase _db;

  Future<void> replaceAll(List<RemoteFeatureFlag> flags) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    await _db.transaction(() async {
      await _db.customStatement('DELETE FROM remote_feature_flags;');
      for (final flag in flags) {
        await _db.customInsert(
          '''
            INSERT INTO remote_feature_flags(
              key, value_type, value, rollout_percent, target_countries,
              is_active, synced_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET
              value_type = excluded.value_type,
              value = excluded.value,
              rollout_percent = excluded.rollout_percent,
              target_countries = excluded.target_countries,
              is_active = excluded.is_active,
              synced_at = excluded.synced_at;
          ''',
          variables: [
            Variable.withString(flag.key),
            Variable.withString(flag.valueType),
            Variable.withString(flag.value),
            Variable.withInt(flag.rolloutPercent),
            Variable.withString(jsonEncode(flag.targetCountries)),
            Variable.withInt(boolToSql(flag.isActive)),
            Variable.withString(now),
          ],
        );
      }
    });
  }

  Future<List<RemoteFeatureFlag>> getAllActiveFlags() async {
    final rows = await _db
        .customSelect(
          'SELECT * FROM remote_feature_flags WHERE is_active = 1;',
        )
        .get();
    return rows.map(_flagFromRow).toList();
  }

  RemoteFeatureFlag _flagFromRow(QueryRow row) {
    return RemoteFeatureFlag(
      key: row.read<String>('key'),
      valueType: row.read<String>('value_type'),
      value: row.read<String>('value'),
      rolloutPercent: row.read<int>('rollout_percent'),
      targetCountries: _jsonStringList(row.read<String>('target_countries')),
      isActive: sqlToBool(row.read<int>('is_active')),
      syncedAt: dateTimeFromSql(row.read<String>('synced_at')),
    );
  }
}

// ─────────────────────────────────────────────────────────
// Announcements
// ─────────────────────────────────────────────────────────

class RemoteAnnouncement {
  const RemoteAnnouncement({
    required this.id,
    required this.titleAr,
    required this.titleEn,
    required this.bodyAr,
    required this.bodyEn,
    required this.severity,
    required this.minAppVersion,
    required this.maxAppVersion,
    required this.actionLabelAr,
    required this.actionLabelEn,
    required this.actionUrl,
    required this.validFrom,
    required this.validUntil,
    required this.isDismissible,
    required this.priority,
    required this.isDismissed,
    required this.dismissedAt,
    required this.syncedAt,
  });

  final String id;
  final String titleAr;
  final String titleEn;
  final String? bodyAr;
  final String? bodyEn;
  final String severity; // 'info'|'warning'|'maintenance'|'force_update'
  final String? minAppVersion;
  final String? maxAppVersion;
  final String? actionLabelAr;
  final String? actionLabelEn;
  final String? actionUrl;
  final DateTime validFrom;
  final DateTime? validUntil;
  final bool isDismissible;
  final int priority;
  final bool isDismissed;
  final DateTime? dismissedAt;
  final DateTime syncedAt;

  bool get isForceUpdate => severity == 'force_update';

  static RemoteAnnouncement fromJson(Map<String, Object?> json) {
    return RemoteAnnouncement(
      id: json['id'].toString(),
      titleAr: json['title_ar'].toString(),
      titleEn: json['title_en'].toString(),
      bodyAr: _optionalString(json['body_ar']),
      bodyEn: _optionalString(json['body_en']),
      severity: json['severity'].toString(),
      minAppVersion: _optionalString(json['min_app_version']),
      maxAppVersion: _optionalString(json['max_app_version']),
      actionLabelAr: _optionalString(json['action_label_ar']),
      actionLabelEn: _optionalString(json['action_label_en']),
      actionUrl: _optionalString(json['action_url']),
      validFrom: _dateTimeFromJson(json['valid_from']),
      validUntil: json['valid_until'] != null
          ? _dateTimeFromJson(json['valid_until'])
          : null,
      isDismissible: json['is_dismissible'] as bool? ?? true,
      priority: (json['priority'] as num?)?.toInt() ?? 0,
      isDismissed: false,
      dismissedAt: null,
      syncedAt: DateTime.now().toUtc(),
    );
  }
}

class RemoteAnnouncementsDao {
  RemoteAnnouncementsDao(this._db);

  final AppDatabase _db;

  /// Full replace from server, preserving local is_dismissed state.
  Future<void> replaceAll(List<RemoteAnnouncement> announcements) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    await _db.transaction(() async {
      // Collect currently dismissed IDs before wiping.
      final dismissedRows = await _db
          .customSelect(
            'SELECT id FROM remote_announcements WHERE is_dismissed = 1;',
          )
          .get();
      final dismissedIds =
          dismissedRows.map((r) => r.read<String>('id')).toSet();

      await _db.customStatement('DELETE FROM remote_announcements;');

      for (final a in announcements) {
        final wasDismissed = dismissedIds.contains(a.id);
        await _db.customInsert(
          '''
            INSERT INTO remote_announcements(
              id, title_ar, title_en, body_ar, body_en, severity,
              min_app_version, max_app_version, action_label_ar,
              action_label_en, action_url, valid_from, valid_until,
              is_dismissible, priority, is_dismissed, dismissed_at, synced_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?);
          ''',
          variables: [
            Variable.withString(a.id),
            Variable.withString(a.titleAr),
            Variable.withString(a.titleEn),
            _nullableString(a.bodyAr),
            _nullableString(a.bodyEn),
            Variable.withString(a.severity),
            _nullableString(a.minAppVersion),
            _nullableString(a.maxAppVersion),
            _nullableString(a.actionLabelAr),
            _nullableString(a.actionLabelEn),
            _nullableString(a.actionUrl),
            Variable.withString(dateTimeToSql(a.validFrom)),
            a.validUntil != null
                ? Variable.withString(dateTimeToSql(a.validUntil!))
                : const Variable<String>(null),
            Variable.withInt(boolToSql(a.isDismissible)),
            Variable.withInt(a.priority),
            Variable.withInt(boolToSql(wasDismissed)),
            Variable.withString(now),
          ],
        );
      }
    });
  }

  Future<List<RemoteAnnouncement>> getActiveNonDismissed() async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    final rows = await _db.customSelect(
      '''
        SELECT * FROM remote_announcements
        WHERE is_dismissed = 0
          AND valid_from <= ?
          AND (valid_until IS NULL OR valid_until >= ?)
        ORDER BY priority DESC, valid_from ASC;
      ''',
      variables: [Variable.withString(now), Variable.withString(now)],
    ).get();
    return rows.map(_announcementFromRow).toList();
  }

  Future<void> setDismissed(String id) async {
    await _db.customUpdate(
      '''
        UPDATE remote_announcements
        SET is_dismissed = 1, dismissed_at = ?
        WHERE id = ?;
      ''',
      variables: [
        Variable.withString(dateTimeToSql(DateTime.now().toUtc())),
        Variable.withString(id),
      ],
    );
  }

  RemoteAnnouncement _announcementFromRow(QueryRow row) {
    final validUntilRaw = row.readNullable<String>('valid_until');
    final dismissedAtRaw = row.readNullable<String>('dismissed_at');
    return RemoteAnnouncement(
      id: row.read<String>('id'),
      titleAr: row.read<String>('title_ar'),
      titleEn: row.read<String>('title_en'),
      bodyAr: row.readNullable<String>('body_ar'),
      bodyEn: row.readNullable<String>('body_en'),
      severity: row.read<String>('severity'),
      minAppVersion: row.readNullable<String>('min_app_version'),
      maxAppVersion: row.readNullable<String>('max_app_version'),
      actionLabelAr: row.readNullable<String>('action_label_ar'),
      actionLabelEn: row.readNullable<String>('action_label_en'),
      actionUrl: row.readNullable<String>('action_url'),
      validFrom: dateTimeFromSql(row.read<String>('valid_from')),
      validUntil: validUntilRaw != null ? dateTimeFromSql(validUntilRaw) : null,
      isDismissible: sqlToBool(row.read<int>('is_dismissible')),
      priority: row.read<int>('priority'),
      isDismissed: sqlToBool(row.read<int>('is_dismissed')),
      dismissedAt:
          dismissedAtRaw != null ? dateTimeFromSql(dismissedAtRaw) : null,
      syncedAt: dateTimeFromSql(row.read<String>('synced_at')),
    );
  }
}
