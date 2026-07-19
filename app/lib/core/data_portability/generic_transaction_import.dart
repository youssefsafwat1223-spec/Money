import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:intl/intl.dart';

import 'data_portability_models.dart';
import 'portable_csv.dart';

enum ImportedDirection { expense, income, transfer, unknown }

class GenericImportRecord {
  const GenericImportRecord({
    required this.recordId,
    required this.rowNumber,
    required this.occurredAt,
    required this.amount,
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
  final double amount;
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

    final amountResult = _amountAndDirection(row, mapping);
    if (amountResult == null || amountResult.$1 <= 0) {
      issues.add(ImportIssue(
        message: 'المبلغ غير صالح أو يساوي صفرًا.',
        severity: ImportIssueSeverity.error,
        rowNumber: rowNumber,
        field: mapping.amountColumn,
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
    final merchant = _nullable(row[mapping.merchantColumn]);
    final category = _nullable(row[mapping.categoryColumn]);
    final account = _nullable(row[mapping.accountColumn]);
    final note = _nullable(row[mapping.noteColumn]);
    final fingerprint = [
      occurredAt.toUtc().toIso8601String(),
      amountResult.$1.toStringAsFixed(6),
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
      amount: amountResult.$1,
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

(double, ImportedDirection)? _amountAndDirection(
  Map<String, String> row,
  CsvColumnMapping mapping,
) {
  final debit = parseImportAmount(row[mapping.debitColumn] ?? '');
  final credit = parseImportAmount(row[mapping.creditColumn] ?? '');
  if (debit != null && debit != 0) {
    return (debit.abs(), ImportedDirection.expense);
  }
  if (credit != null && credit != 0) {
    return (credit.abs(), ImportedDirection.income);
  }
  final amount = parseImportAmount(row[mapping.amountColumn] ?? '');
  if (amount == null) return null;
  final explicit = _parseDirection(row[mapping.typeColumn]);
  if (explicit != ImportedDirection.unknown) return (amount.abs(), explicit);
  final expense = mapping.negativeMeansExpense ? amount < 0 : amount > 0;
  return (
    amount.abs(),
    expense ? ImportedDirection.expense : ImportedDirection.income,
  );
}

double? parseImportAmount(String input) {
  var value =
      _normalizeDigits(input).replaceAll(RegExp(r'[^0-9,\.\-+]'), '').trim();
  if (value.isEmpty || value == '-' || value == '+') return null;
  final lastComma = value.lastIndexOf(',');
  final lastDot = value.lastIndexOf('.');
  if (lastComma >= 0 && lastDot >= 0) {
    if (lastComma > lastDot) {
      value = value.replaceAll('.', '').replaceFirst(',', '.');
    } else {
      value = value.replaceAll(',', '');
    }
  } else if (lastComma >= 0) {
    final decimals = value.length - lastComma - 1;
    value = decimals == 3
        ? value.replaceAll(',', '')
        : value.replaceFirst(',', '.');
  }
  return double.tryParse(value);
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
