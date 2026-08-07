import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/catalog/feature_flag_service.dart';
import '../../data/db/app_database.dart';
import '../../data/db/financial_cache_health.dart';
import '../../core/utils/id_generator.dart';
import '../../domain/entities/account_entity.dart';
import '../../domain/entities/category_entity.dart';
import '../../domain/entities/transaction_entity.dart';
import '../../domain/repositories/account_repository.dart';
import '../../domain/repositories/category_repository.dart';
import '../../domain/repositories/transaction_repository.dart';
import '../../domain/repositories/user_settings_repository.dart';
import '../backend/supabase_config.dart';
import 'data_portability_models.dart';
import 'drift_financial_exporter.dart';
import 'drift_financial_importer.dart';
import 'generic_transaction_import.dart';
import 'package:money_companion/core/data_portability/import_normalizer.dart';
import 'package:money_companion/core/data_portability/portable_csv.dart';
import 'package:money_companion/core/data_portability/qirsh_package_codec.dart';

class AppDataPortabilityService implements DataPortabilityService {
  AppDataPortabilityService({
    required AppDatabase db,
    required AccountRepository accounts,
    required CategoryRepository categories,
    required TransactionRepository transactions,
    required UserSettingsRepository settings,
    required FeatureFlagService Function() flags,
    SupabaseClient Function()? getSupabase,
    Future<Object?> Function(String functionName, Map<String, dynamic> params)?
        invokeRpc,
    Future<void> Function()? repairFinancialCache,
  })  : _db = db,
        _accounts = accounts,
        _categories = categories,
        _transactions = transactions,
        _settings = settings,
        _flags = flags,
        _getSupabase = getSupabase,
        _invokeRpc = invokeRpc,
        _repairFinancialCache = repairFinancialCache;

  final AppDatabase _db;
  final AccountRepository _accounts;
  final CategoryRepository _categories;
  final TransactionRepository _transactions;
  final UserSettingsRepository _settings;
  final FeatureFlagService Function() _flags;
  final SupabaseClient Function()? _getSupabase;
  final Future<Object?> Function(
    String functionName,
    Map<String, dynamic> params,
  )? _invokeRpc;
  final Future<void> Function()? _repairFinancialCache;

  final Map<String, Object> _inspected = {};

  @override
  Future<ExportedFile> exportTransactionsCsv() async {
    final transactions = await _transactions.getAll();
    final accounts = {
      for (final account in await _accounts.getAll()) account.id: account
    };
    final categories = {
      for (final category in await _categories.getAll()) category.id: category
    };
    const headers = [
      'record_id',
      'occurred_at',
      'amount',
      'currency',
      'direction',
      'type',
      'source',
      'status',
      'merchant',
      'category_key',
      'category',
      'account',
      'card_last4',
      'balance_after',
      'foreign_amount',
      'foreign_currency',
      'note',
    ];
    final bytes = encodePortableCsv(headers, transactions.map((transaction) {
      final category = categories[transaction.categoryId];
      return [
        transaction.id,
        transaction.occurredAt.toUtc().toIso8601String(),
        transaction.amount,
        transaction.currency,
        transaction.direction?.name ?? 'unknown',
        transaction.type.name,
        transaction.source.name,
        transaction.status.name,
        transaction.rawMerchant,
        category?.key,
        category?.nameAr,
        accounts[transaction.accountId]?.name,
        transaction.cardLast4,
        transaction.balanceAfter,
        transaction.foreignAmount,
        transaction.foreignCurrency,
        transaction.note,
      ];
    }));
    final now = DateTime.now().toUtc();
    String two(int value) => value.toString().padLeft(2, '0');
    return ExportedFile(
      name:
          'qirsh-transactions-${now.year}-${two(now.month)}-${two(now.day)}.csv',
      mimeType: 'text/csv',
      bytes: bytes,
      recordCount: transactions.length,
    );
  }

  @override
  Future<ExportedFile> exportFinancialPackage() async {
    if (_anyFinancialPrimary && !_allFinancialPrimary) {
      throw const DataPortabilityException(
        'تصدير الحزمة الكاملة غير متاح أثناء تشغيل مصادر بيانات مختلطة.',
      );
    }
    if (_allFinancialPrimary) {
      if (_repairFinancialCache == null) {
        throw const DataPortabilityException(
            'تعذر تجهيز مرآة البيانات للتصدير.');
      }
      await _categories.getAll();
      await _repairFinancialCache();
    }
    return DriftFinancialExporter(_db).exportFinancialPackage();
  }

  @override
  Future<ImportPreview> inspectFile(String path) async {
    final file = File(path);
    final length = await file.length();
    if (length > maxImportBytes) {
      throw const DataPortabilityException('حجم الملف أكبر من 25MB.');
    }
    var bytes = await file.readAsBytes();
    final lower = path.toLowerCase();
    if (lower.endsWith('.zip')) {
      try {
        final package = decodeQirshPackage(bytes);
        _inspected[package.packageId] = package;
        return ImportPreview(
          sourcePath: path,
          format: ImportFormat.qirshPackage,
          packageId: package.packageId,
          totalRows: package.totalRows,
          tableCounts: {
            for (final entry in package.tables.entries)
              entry.key: entry.value.rows.length,
          },
          issues: const [],
          canReplace: _canReplacePackage,
        );
      } catch (error) {
        // Not a valid Qirsh package. Check if it's a ZIP containing a single CSV (e.g. from a bank).
        Archive archive;
        try {
          archive = ZipDecoder().decodeBytes(bytes);
        } catch (_) {
          throw const DataPortabilityException('ملف ZIP غير صالح أو تالف.');
        }
        final csvFiles = archive.files
            .where((f) => f.isFile && f.name.toLowerCase().endsWith('.csv'))
            .toList(growable: false);
        if (csvFiles.length == 1) {
          bytes = csvFiles.single.content;
        } else {
          throw DataPortabilityException(
            error is DataPortabilityException
                ? error.message
                : 'ملف ZIP يجب أن يكون نسخة قرش أو أن يحتوي على ملف CSV واحد.',
          );
        }
      }
    } else if (!lower.endsWith('.csv')) {
      throw const DataPortabilityException('اختر ملف CSV أو ZIP.');
    }
    final document = decodePortableCsv(bytes);
    final guessedMapping = guessCsvMapping(document.headers);
    final mapping = guessedMapping ??
        (document.headers.length >= 2
            ? CsvColumnMapping(
                dateColumn: document.headers.first,
                amountColumn: document.headers[1],
              )
            : null);
    final packageId = 'csv_${sha256.convert(bytes)}';
    _inspected[packageId] = document;
    final issues = <ImportIssue>[];
    if (mapping == null) {
      issues.add(const ImportIssue(
        message: 'CSV يحتاج عمودين على الأقل: التاريخ والمبلغ.',
        severity: ImportIssueSeverity.error,
      ));
    } else if (guessedMapping == null) {
      issues.add(const ImportIssue(
        message: 'لم نتعرف على العناوين تلقائياً. راجع مطابقة الأعمدة.',
        severity: ImportIssueSeverity.warning,
      ));
    }
    final defaultCurrency = (await _settings.getSettings()).currency;
    final duplicates = <String>{};
    if (mapping != null) {
      final parsed = parseGenericTransactions(
        document: document,
        mapping: mapping,
        defaultCurrency: defaultCurrency,
      );
      issues.addAll(parsed.issues);
      for (final record in parsed.records) {
        final duplicate = await _transactions.findSuspiciousDuplicate(
          amount: record.amount,
          currency: record.currency,
          merchantOrDescription: record.merchant ?? record.note ?? '',
          comparisonTimestamp: record.occurredAt,
        );
        if (duplicate != null) duplicates.add(record.recordId);
      }
      if (duplicates.isNotEmpty) {
        issues.add(ImportIssue(
          message:
              '${duplicates.length} عملية مشابهة موجودة وستُعرض قبل الحفظ.',
          severity: ImportIssueSeverity.warning,
        ));
      }
    }
    return ImportPreview(
      sourcePath: path,
      format: ImportFormat.genericCsv,
      packageId: packageId,
      totalRows: document.rows.length,
      tableCounts: {'transactions': document.rows.length},
      issues: issues,
      canReplace: false,
      headers: document.headers,
      sampleRows: document.rows.take(5).toList(growable: false),
      mapping: mapping,
      defaultAccountId: (await _accounts.getDefault())?.id,
      duplicateRecordIds: duplicates,
    );
  }

  @override
  Future<ImportResult> import(ImportPreview preview, ImportMode mode) async {
    if (preview.hasErrors) {
      throw const DataPortabilityException('أصلح أخطاء الملف قبل الاستيراد.');
    }
    if (preview.format == ImportFormat.genericCsv) {
      if (mode == ImportMode.replace) {
        throw const DataPortabilityException('CSV الخارجي يدعم الدمج فقط.');
      }
      return _importGeneric(preview);
    }
    if (mode == ImportMode.replace && !preview.canReplace) {
      throw const DataPortabilityException(
        'الاستبدال غير متاح أثناء تشغيل مصادر بيانات مختلطة.',
      );
    }
    final package = _inspected[preview.packageId];
    if (package is! QirshPackageData) {
      throw const DataPortabilityException(
          'أعد اختيار الملف ثم حاول مرة أخرى.');
    }
    if (_allFinancialPrimary) return _importServerPackage(package, mode);
    if (_anyFinancialPrimary) return _importMixedPackage(package, mode);
    return DriftFinancialImporter(_db).importPackage(package, mode);
  }

  Future<ImportResult> _importGeneric(ImportPreview preview) async {
    final document = _inspected[preview.packageId];
    final mapping = preview.mapping;
    if (document is! PortableCsvDocument || mapping == null) {
      throw const DataPortabilityException('مطابقة أعمدة CSV غير مكتملة.');
    }
    final defaultCurrency = (await _settings.getSettings()).currency;
    final parsed = parseGenericTransactions(
      document: document,
      mapping: mapping,
      defaultCurrency: defaultCurrency,
    );
    final accounts = await _accounts.getAll();
    final categories = await _categories.getAll();
    var imported = 0;
    var duplicates = 0;
    var failed = parsed.issues
        .where((issue) => issue.severity == ImportIssueSeverity.error)
        .length;
    for (final record in parsed.records) {
      final liveDuplicate = await _transactions.findSuspiciousDuplicate(
        amount: record.amount,
        currency: record.currency,
        merchantOrDescription: record.merchant ?? record.note ?? '',
        comparisonTimestamp: record.occurredAt,
      );
      if ((preview.duplicateRecordIds.contains(record.recordId) ||
              liveDuplicate != null) &&
          !preview.confirmedDuplicateRecordIds.contains(record.recordId)) {
        duplicates += 1;
        continue;
      }
      try {
        final importAsNew =
            preview.confirmedDuplicateRecordIds.contains(record.recordId);
        final account = await _resolveAccount(
          record,
          accounts,
          preview.defaultAccountId,
        );
        final category = await _resolveCategory(record, categories);
        final now = DateTime.now().toUtc();
        await _transactions.saveTransaction(
          transaction: TransactionEntity(
            id: importAsNew ? IdGenerator.next() : record.recordId,
            amount: record.amount,
            currency: record.currency,
            accountId: account?.id,
            rawMerchant: record.merchant,
            categoryId: category?.id,
            type: switch (record.direction) {
              ImportedDirection.expense => TransactionTypeEntity.payment,
              ImportedDirection.income => TransactionTypeEntity.income,
              ImportedDirection.transfer => TransactionTypeEntity.transfer,
              ImportedDirection.unknown => TransactionTypeEntity.unknown,
            },
            source: TransactionSourceEntity.imported,
            occurredAt: record.occurredAt,
            rawMessage: '',
            parseConfidence: 1,
            status: TransactionStatus.confirmed,
            createdAt: now,
            updatedAt: now,
            note: record.note,
            direction: record.direction == ImportedDirection.income
                ? TransactionDirectionEntity.credit
                : record.direction == ImportedDirection.expense
                    ? TransactionDirectionEntity.debit
                    : TransactionDirectionEntity.unknown,
            comparisonTimestamp: record.occurredAt,
          ),
          categoryKey: category?.key,
          // MALI-029: `_resolveCategory` already found this category in the
          // once-fetched `categories` list — pass its id so saveTransaction does
          // not re-run a per-row `_categoryIdByKey` SELECT.
          resolvedCategoryId: category?.id,
        );
        imported += 1;
      } catch (_) {
        failed += 1;
      }
    }
    return ImportResult(
      imported: imported,
      duplicates: duplicates,
      skipped: 0,
      failed: failed,
    );
  }

  Future<AccountEntity?> _resolveAccount(
    GenericImportRecord record,
    List<AccountEntity> cache,
    String? defaultAccountId,
  ) async {
    if (record.accountName == null) {
      if (defaultAccountId != null) {
        return cache.where((a) => a.id == defaultAccountId).firstOrNull;
      }
      return _accounts.getDefault();
    }
    final accountName = record.accountName!;
    final normalized = accountName.trim().toLowerCase();
    final found = cache
        .where((account) =>
            account.name.trim().toLowerCase() == normalized &&
            account.currency == record.currency)
        .firstOrNull;
    if (found != null) return found;
    final now = DateTime.now().toUtc();
    final created = await _accounts.create(AccountEntity(
      id: '',
      name: accountName,
      currency: record.currency,
      type: AccountType.bank,
      isDefault: cache.isEmpty,
      sortOrder: cache.length,
      createdAt: now,
      updatedAt: now,
    ));
    cache.add(created);
    return created;
  }

  Future<CategoryEntity?> _resolveCategory(
    GenericImportRecord record,
    List<CategoryEntity> cache,
  ) async {
    final label = record.category?.trim();
    if (label == null || label.isEmpty) return null;
    final normalized = label.toLowerCase();
    final found = cache
        .where((category) =>
            category.key.toLowerCase() == normalized ||
            category.nameAr.trim().toLowerCase() == normalized)
        .firstOrNull;
    if (found != null) return found;
    final created = await _categories.createCategory(
      nameAr: label,
      icon: 'category',
      color: '#64748B',
      isIncome: record.direction == ImportedDirection.income,
    );
    cache.add(created);
    return created;
  }

  bool get _allFinancialPrimary {
    final flags = _flags();
    return const [
      'accounts_supabase_primary',
      'transactions_supabase_primary',
      'budgets_supabase_primary',
      'goals_supabase_primary',
      'subscriptions_supabase_primary',
      'plans_supabase_primary',
    ].every(flags.getBool);
  }

  bool get _anyFinancialPrimary {
    final flags = _flags();
    return const [
      'accounts_supabase_primary',
      'transactions_supabase_primary',
      'budgets_supabase_primary',
      'goals_supabase_primary',
      'subscriptions_supabase_primary',
      'plans_supabase_primary',
    ].any(flags.getBool);
  }

  bool get _canReplacePackage => !_anyFinancialPrimary || _allFinancialPrimary;

  Future<ImportResult> _importServerPackage(
    QirshPackageData package,
    ImportMode mode,
  ) async {
    try {
      final result = await _callImportRpc(package, mode);
      var repairPending = false;
      try {
        await _categories.getAll();
        await _repairFinancialCache?.call();
      } catch (_) {
        repairPending = true;
      }
      return ImportResult(
        imported: (result['imported'] as num?)?.toInt() ?? 0,
        duplicates: (result['duplicates'] as num?)?.toInt() ?? 0,
        skipped: (result['skipped'] as num?)?.toInt() ?? 0,
        failed: 0,
        cacheRepairPending: repairPending,
      );
    } catch (error) {
      String message = 'تعذر إتمام الاستيراد بسبب خطأ غير معروف.';
      final errStr = error.toString();

      if (errStr.contains('PostgrestException')) {
        message =
            'حدث تعارض في البيانات مع الخادم. يرجى التأكد من عدم وجود تكرار في الحسابات أو العمليات.';
      } else if (errStr.contains('FormatException')) {
        message = 'ملف النسخة الاحتياطية يحتوي على بيانات غير صالحة أو تالفة.';
      } else if (errStr.contains('DataPortabilityException')) {
        message = errStr.replaceAll('DataPortabilityException: ', '');
      }

      throw DataPortabilityException('فشل الاستيراد: $message');
    }
  }

  Future<ImportResult> _importMixedPackage(
    QirshPackageData package,
    ImportMode mode,
  ) async {
    if (mode != ImportMode.merge) {
      throw const DataPortabilityException(
        'الاستبدال غير متاح أثناء تشغيل مصادر بيانات مختلطة.',
      );
    }
    final result = await _callImportRpc(package, mode);
    var repairPending = false;
    try {
      await DriftFinancialImporter(_db).importPackage(package, mode);
    } catch (error) {
      repairPending = true;
      for (final entityType in const [
        accountsCacheEntityType,
        transactionsCacheEntityType,
        budgetsCacheEntityType,
        goalsCacheEntityType,
        subscriptionsCacheEntityType,
        plansCacheEntityType,
      ]) {
        try {
          await markFinancialCacheDirty(_db, entityType, error.runtimeType);
        } catch (_) {}
      }
    }
    return ImportResult(
      imported: (result['imported'] as num?)?.toInt() ?? 0,
      duplicates: (result['duplicates'] as num?)?.toInt() ?? 0,
      skipped: (result['skipped'] as num?)?.toInt() ?? 0,
      failed: 0,
      cacheRepairPending: repairPending,
    );
  }

  Future<Map<String, dynamic>> _callImportRpc(
    QirshPackageData package,
    ImportMode mode,
  ) async {
    final Map<String, List<Map<String, String>>> rawTables = {
      for (final entry in package.tables.entries)
        entry.key: List.of(entry.value.rows.map((r) => Map.of(r))),
    };

    final tables = ImportNormalizer.normalize(rawTables, mode);

    final params = <String, dynamic>{
      'p_import_id': package.packageId,
      'p_mode': mode.name,
      'p_package': tables,
    };
    final Object? response;
    if (_invokeRpc != null) {
      response = await _invokeRpc('import_financial_package', params);
    } else {
      if (!SupabaseConfig.isConfigured || _getSupabase == null) {
        throw const DataPortabilityException('اتصال Supabase غير متاح.');
      }
      response = await _getSupabase().rpc(
        'import_financial_package',
        params: params,
      );
    }
    if (response is! Map) {
      throw const DataPortabilityException('استجابة الاستيراد غير صالحة.');
    }
    return Map<String, dynamic>.from(response);
  }
}
