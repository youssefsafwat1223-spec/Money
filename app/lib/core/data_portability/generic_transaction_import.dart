import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:intl/intl.dart';

import '../../domain/finance/money.dart';
import '../../domain/finance/money_input.dart';
import 'data_portability_models.dart';
import 'portable_csv.dart';

enum ImportedDirection { expense, income, transfer, unknown }

class GenericImportRecord {
  const GenericImportRecord({
    required this.recordId,
    required this.rowNumber,
    required this.occurredAt,
    required this.amountMoney,
    required this.currency,
    required this.direction,
    required this.accountName,
    required this.merchant,
    required this.category,
    required this.note,
  });

  final String recordId;
  final int rowNumber;
  final DateTime occurredAt;
  final Money amountMoney;
  /// DISPLAY-ONLY compatibility projection for import previews.
  double get amount => amountMoney.toDouble();
  final String currency;
  final ImportedDirection direction;
  final String? accountName;
  final String? merchant;
  final String? category;
  final String? note;
}

class GenericImportParseResult {
  const GenericImportParseResult({
    required this.records,
    required this.issues,
  });

  final List<GenericImportRecord> records;
  final List<ImportIssue> issues;
}

GenericImportParseResult parseGenericTransactions({
  required PortableCsvDocument document,
  required CsvColumnMapping mapping,
  required String defaultCurrency,
}) {
  final records = <GenericImportRecord>[];
  final issues = <ImportIssue>[];
  for (var index = 0; index < document.rows.length; index++) {
    final rowNumber = index + 2;
    final row = document.rows[index];
    final dateText = row[mapping.dateColumn]?.trim() ?? '';
    final occurredAt = parseImportDate(dateText, mapping.dateFormat);
    if (occurredAt == null) {
      issues.add(ImportIssue(
        message: 'تعذر قراءة التاريخ.',
        severity: ImportIssueSeverity.error,
        rowNumber: rowNumber,
        field: mapping.dateColumn,
      ));
      continue;
    }

    final currency = (mapping.currencyColumn == null
            ? defaultCurrency
            : row[mapping.currencyColumn]?.trim())
        ?.toUpperCase();
    if (currency == null || !RegExp(r'^[A-Z]{3}$').hasMatch(currency)) {
      issues.add(ImportIssue(
        message: 'العملة يجب أن تكون رمز ISO من 3 أحرف.',
        severity: ImportIssueSeverity.error,
        rowNumber: rowNumber,
        field: mapping.currencyColumn,
      ));
      continue;
    }
    final amountResult = _amountAndDirection(row, mapping, currency);
    if (amountResult == null || amountResult.$1.isZero) {
      issues.add(ImportIssue(
        message: 'المبلغ غير صالح أو يساوي صفرًا.',
        severity: ImportIssueSeverity.error,
        rowNumber: rowNumber,
        field: mapping.amountColumn,
      ));
      continue;
    }
    final merchant = _nullable(row[mapping.merchantColumn]);
    final category = _nullable(row[mapping.categoryColumn]);
    final account = _nullable(row[mapping.accountColumn]);
    final note = _nullable(row[mapping.noteColumn]);
    final fingerprint = [
      occurredAt.toUtc().toIso8601String(),
      amountResult.$1.toDecimalString(),
      currency,
      amountResult.$2.name,
      account?.toLowerCase() ?? '',
      merchant?.toLowerCase() ?? '',
      category?.toLowerCase() ?? '',
      note ?? '',
    ].join('|');
    records.add(GenericImportRecord(
      recordId: 'import_${sha256.convert(utf8.encode(fingerprint))}',
      rowNumber: rowNumber,
      occurredAt: occurredAt.toUtc(),
      amountMoney: amountResult.$1,
      currency: currency,
      direction: amountResult.$2,
      accountName: account,
      merchant: merchant,
      category: category,
      note: note,
    ));
  }
  return GenericImportParseResult(records: records, issues: issues);
}

DateTime? parseImportDate(String input, ImportDateFormat format) {
  final value = _normalizeDigits(input.trim());
  if (value.isEmpty) return null;
  if (format == ImportDateFormat.automatic ||
      format == ImportDateFormat.iso8601) {
    final parsed = DateTime.tryParse(value);
    if (parsed != null) return parsed;
    if (format == ImportDateFormat.iso8601) return null;
  }
  final patterns = switch (format) {
    ImportDateFormat.dayMonthYear => const ['dd/MM/yyyy', 'd/M/yyyy'],
    ImportDateFormat.monthDayYear => const ['MM/dd/yyyy', 'M/d/yyyy'],
    ImportDateFormat.yearMonthDay => const ['yyyy/MM/dd', 'yyyy-MM-dd'],
    ImportDateFormat.automatic => const [
        'dd/MM/yyyy HH:mm',
        'dd/MM/yyyy',
        'yyyy/MM/dd HH:mm',
        'yyyy/MM/dd',
      ],
    ImportDateFormat.iso8601 => const <String>[],
  };
  for (final pattern in patterns) {
    try {
      return DateFormat(pattern).parseStrict(value);
    } catch (_) {}
  }
  return null;
}

(Money, ImportedDirection)? _amountAndDirection(
  Map<String, String> row,
  CsvColumnMapping mapping,
  String currency,
) {
  final debit = _parseImportMoney(row[mapping.debitColumn] ?? '', currency);
  final credit = _parseImportMoney(row[mapping.creditColumn] ?? '', currency);
  if (debit != null && !debit.isZero) {
    return (debit.isNegative ? -debit : debit, ImportedDirection.expense);
  }
  if (credit != null && !credit.isZero) {
    return (credit.isNegative ? -credit : credit, ImportedDirection.income);
  }
  final amount = _parseImportMoney(row[mapping.amountColumn] ?? '', currency);
  if (amount == null) return null;
  final explicit = _parseDirection(row[mapping.typeColumn]);
  final absolute = amount.isNegative ? -amount : amount;
  if (explicit != ImportedDirection.unknown) return (absolute, explicit);
  final expense = mapping.negativeMeansExpense
      ? amount.isNegative
      : !amount.isNegative && !amount.isZero;
  return (
    absolute,
    expense ? ImportedDirection.expense : ImportedDirection.income,
  );
}

Money? _parseImportMoney(String input, String currency) {
  if (input.trim().isEmpty) return null;
  try {
    return parseLocalizedMoney(input, currency);
  } on Exception {
    return null;
  }
}

ImportedDirection _parseDirection(String? input) {
  final value = normalizeHeader(input ?? '');
  if (const ['expense', 'debit', 'payment', 'withdrawal', 'مصروف', 'مدين']
      .contains(value)) {
    return ImportedDirection.expense;
  }
  if (const ['income', 'credit', 'deposit', 'دخل', 'دائن'].contains(value)) {
    return ImportedDirection.income;
  }
  if (const ['transfer', 'تحويل'].contains(value)) {
    return ImportedDirection.transfer;
  }
  return ImportedDirection.unknown;
}

String? _nullable(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

String _normalizeDigits(String input) {
  const arabic = '٠١٢٣٤٥٦٧٨٩';
  const persian = '۰۱۲۳۴۵۶۷۸۹';
  var result = input;
  for (var index = 0; index < 10; index++) {
    result = result
        .replaceAll(arabic[index], '$index')
        .replaceAll(persian[index], '$index');
  }
  return result;
}
