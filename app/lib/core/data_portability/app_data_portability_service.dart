import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import '../../data/db/app_database.dart';
import '../../core/utils/id_generator.dart';
import '../../domain/entities/account_entity.dart';
import '../../domain/entities/category_entity.dart';
import '../../domain/entities/transaction_entity.dart';
import '../../domain/repositories/account_repository.dart';
import '../../domain/repositories/category_repository.dart';
import '../../domain/repositories/transaction_repository.dart';
import '../../domain/repositories/user_settings_repository.dart';
import 'data_portability_models.dart';
import 'drift_financial_exporter.dart';
import 'drift_financial_importer.dart';
import 'generic_transaction_import.dart';
import 'package:money_companion/core/data_portability/portable_csv.dart';
import 'package:money_companion/core/data_portability/qirsh_package_codec.dart';

class AppDataPortabilityService implements DataPortabilityService {
  AppDataPortabilityService({
    required AppDatabase db,
    required AccountRepository accounts,
    required CategoryRepository categories,
    required TransactionRepository transactions,
    required UserSettingsRepository settings,
  })  : _db = db,
        _accounts = accounts,
        _categories = categories,
        _transactions = transactions,
        _settings = settings;

  final AppDatabase _db;
  final AccountRepository _accounts;
  final CategoryRepository _categories;
  final TransactionRepository _transactions;
  final UserSettingsRepository _settings;

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
    // MALI-034: Drift is the authoritative financial store — export reads local
    // Drift directly; the obsolete Supabase-primary pre-export rebuild is gone.
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
          canReplace: true,
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
    // MALI-034: single Drift-authoritative import path. The Supabase-primary
    // server/mixed import RPC branches (and their repairAll/mark-dirty recovery)
    // are retired; local import is transactional and recorded in the local
    // financial_import_runs for idempotency.
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

}
