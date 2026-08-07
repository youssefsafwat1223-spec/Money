import 'dart:convert';
import 'dart:typed_data';

import 'package:csv/csv.dart';

import 'data_portability_models.dart';

const int maxImportBytes = 25 * 1024 * 1024;
const int maxExpandedImportBytes = 100 * 1024 * 1024;
const int maxImportRows = 100000;

class PortableCsvDocument {
  const PortableCsvDocument({
    required this.headers,
    required this.rows,
  });

  final List<String> headers;
  final List<Map<String, String>> rows;
}

Uint8List encodePortableCsv(
  List<String> headers,
  Iterable<List<Object?>> rows,
) {
  final safeRows = <List<dynamic>>[
    headers,
    for (final row in rows) [for (final value in row) _safeCell(value)],
  ];
  final encoded = Csv(addBom: true, lineDelimiter: '\r\n').encode(safeRows);
  return Uint8List.fromList(utf8.encode(encoded));
}

/// MALI-030 — encodes ONE bounded chunk of rows for a paged/streamed export, so no
/// full row list is ever held. [includeHeader] (first chunk only) prepends the BOM
/// + header row. Chunks join with `\r\n` (`Csv.encode` emits no trailing
/// delimiter), preserving exact CSV escaping and UTF-8/RTL content per chunk.
String encodePortableCsvChunk({
  required List<String> headers,
  required Iterable<List<Object?>> rows,
  required bool includeHeader,
}) {
  final data = <List<dynamic>>[
    if (includeHeader) headers,
    for (final row in rows) [for (final value in row) _safeCell(value)],
  ];
  return Csv(addBom: includeHeader, lineDelimiter: '\r\n').encode(data);
}

PortableCsvDocument decodePortableCsv(Uint8List bytes) {
  if (bytes.length > maxImportBytes) {
    throw const DataPortabilityException('حجم ملف CSV أكبر من 25MB.');
  }
  final text = utf8.decode(bytes, allowMalformed: false);
  final decoded = Csv(autoDetect: true).decode(text);
  if (decoded.isEmpty) {
    throw const DataPortabilityException('ملف CSV فارغ.');
  }
  if (decoded.length - 1 > maxImportRows) {
    throw const DataPortabilityException('ملف CSV يتجاوز 100,000 صف.');
  }
  final headers = decoded.first
      .map((value) => value.toString().replaceFirst('\ufeff', '').trim())
      .toList(growable: false);
  if (headers.isEmpty || headers.any((header) => header.isEmpty)) {
    throw const DataPortabilityException('عناوين أعمدة CSV غير صالحة.');
  }
  if (headers.toSet().length != headers.length) {
    throw const DataPortabilityException('ملف CSV يحتوي أعمدة مكررة.');
  }
  final rows = <Map<String, String>>[];
  for (var index = 1; index < decoded.length; index++) {
    final values = decoded[index];
    if (values.every((value) => value.toString().trim().isEmpty)) continue;
    final row = <String, String>{};
    for (var column = 0; column < headers.length; column++) {
      row[headers[column]] =
          column < values.length ? values[column].toString().trim() : '';
    }
    rows.add(row);
  }
  return PortableCsvDocument(headers: headers, rows: rows);
}

CsvColumnMapping? guessCsvMapping(List<String> headers) {
  String? match(List<String> aliases) {
    for (final header in headers) {
      final normalized = normalizeHeader(header);
      if (aliases.any((alias) => normalized == alias)) return header;
    }
    return null;
  }

  final date = match(const [
    'date',
    'datetime',
    'occurredat',
    'transactiondate',
    'التاريخ',
    'تاريخ',
  ]);
  final amount = match(const [
    'amount',
    'value',
    'transactionamount',
    'المبلغ',
    'قيمة',
  ]);
  final debit =
      match(const ['debit', 'expense', 'withdrawal', 'مدين', 'مصروف']);
  final credit = match(const ['credit', 'income', 'deposit', 'دائن', 'دخل']);
  if (date == null || (amount == null && debit == null && credit == null)) {
    return null;
  }
  return CsvColumnMapping(
    dateColumn: date,
    amountColumn: amount ?? debit ?? credit!,
    debitColumn: debit,
    creditColumn: credit,
    currencyColumn: match(const ['currency', 'currencycode', 'العملة']),
    accountColumn: match(const ['account', 'accountname', 'الحساب']),
    merchantColumn: match(const [
      'merchant',
      'description',
      'payee',
      'vendor',
      'التاجر',
      'الوصف',
    ]),
    categoryColumn: match(const ['category', 'categoryname', 'التصنيف']),
    noteColumn: match(const ['note', 'notes', 'memo', 'ملاحظات', 'ملاحظة']),
    typeColumn: match(const ['type', 'transactiontype', 'النوع']),
  );
}

String normalizeHeader(String value) => value
    .trim()
    .toLowerCase()
    .replaceAll(RegExp(r'[\s_\-./]+'), '')
    .replaceAll(RegExp(r'[():]'), '');

Object? _safeCell(Object? value) {
  if (value == null || value is num || value is bool) return value ?? '';
  final text = value.toString();
  if (text.isEmpty) return text;
  if (const {'=', '+', '-', '@'}.contains(text[0])) return "'$text";
  return text;
}
