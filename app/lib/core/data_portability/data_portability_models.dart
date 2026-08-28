import 'dart:typed_data';

enum ImportMode { merge, replace }

enum ImportFormat { qirshPackage, genericCsv }

enum ImportIssueSeverity { warning, error }

enum ImportDateFormat {
  automatic,
  iso8601,
  dayMonthYear,
  monthDayYear,
  yearMonthDay,
}

class ExportedFile {
  const ExportedFile({
    required this.name,
    required this.mimeType,
    required this.bytes,
    required this.recordCount,
  });

  final String name;
  final String mimeType;
  final Uint8List bytes;
  final int recordCount;
}

class ImportIssue {
  const ImportIssue({
    required this.message,
    required this.severity,
    this.rowNumber,
    this.field,
  });

  final String message;
  final ImportIssueSeverity severity;
  final int? rowNumber;
  final String? field;
}

class CsvColumnMapping {
  const CsvColumnMapping({
    required this.dateColumn,
    required this.amountColumn,
    this.currencyColumn,
    this.accountColumn,
    this.merchantColumn,
    this.categoryColumn,
    this.noteColumn,
    this.typeColumn,
    this.debitColumn,
    this.creditColumn,
    this.dateFormat = ImportDateFormat.automatic,
    this.negativeMeansExpense = true,
  });

  final String dateColumn;
  final String amountColumn;
  final String? currencyColumn;
  final String? accountColumn;
  final String? merchantColumn;
  final String? categoryColumn;
  final String? noteColumn;
  final String? typeColumn;
  final String? debitColumn;
  final String? creditColumn;
  final ImportDateFormat dateFormat;
  final bool negativeMeansExpense;

  CsvColumnMapping copyWith({
    String? dateColumn,
    String? amountColumn,
    String? currencyColumn,
    String? accountColumn,
    String? merchantColumn,
    String? categoryColumn,
    String? noteColumn,
    String? typeColumn,
    String? debitColumn,
    String? creditColumn,
    ImportDateFormat? dateFormat,
    bool? negativeMeansExpense,
  }) {
    return CsvColumnMapping(
      dateColumn: dateColumn ?? this.dateColumn,
      amountColumn: amountColumn ?? this.amountColumn,
      currencyColumn: currencyColumn ?? this.currencyColumn,
      accountColumn: accountColumn ?? this.accountColumn,
      merchantColumn: merchantColumn ?? this.merchantColumn,
      categoryColumn: categoryColumn ?? this.categoryColumn,
      noteColumn: noteColumn ?? this.noteColumn,
      typeColumn: typeColumn ?? this.typeColumn,
      debitColumn: debitColumn ?? this.debitColumn,
      creditColumn: creditColumn ?? this.creditColumn,
      dateFormat: dateFormat ?? this.dateFormat,
      negativeMeansExpense: negativeMeansExpense ?? this.negativeMeansExpense,
    );
  }
}

class ImportPreview {
  const ImportPreview({
    required this.sourcePath,
    required this.format,
    required this.packageId,
    required this.totalRows,
    required this.tableCounts,
    required this.issues,
    required this.canReplace,
    this.headers = const [],
    this.sampleRows = const [],
    this.mapping,
    this.defaultAccountId,
    this.duplicateRecordIds = const {},
    this.confirmedDuplicateRecordIds = const {},
  });

  final String sourcePath;
  final ImportFormat format;
  final String packageId;
  final int totalRows;
  final Map<String, int> tableCounts;
  final List<ImportIssue> issues;
  final bool canReplace;
  final List<String> headers;
  final List<Map<String, String>> sampleRows;
  final CsvColumnMapping? mapping;
  final String? defaultAccountId;
  final Set<String> duplicateRecordIds;
  final Set<String> confirmedDuplicateRecordIds;

  bool get hasErrors => issues.any(
        (issue) =>
            issue.severity == ImportIssueSeverity.error &&
            issue.rowNumber == null,
      );

  ImportPreview copyWith({
    CsvColumnMapping? mapping,
    List<ImportIssue>? issues,
    bool? canReplace,
    String? defaultAccountId,
    Set<String>? confirmedDuplicateRecordIds,
  }) {
    return ImportPreview(
      sourcePath: sourcePath,
      format: format,
      packageId: packageId,
      totalRows: totalRows,
      tableCounts: tableCounts,
      issues: issues ?? this.issues,
      canReplace: canReplace ?? this.canReplace,
      headers: headers,
      sampleRows: sampleRows,
      mapping: mapping ?? this.mapping,
      defaultAccountId: defaultAccountId ?? this.defaultAccountId,
      duplicateRecordIds: duplicateRecordIds,
      confirmedDuplicateRecordIds:
          confirmedDuplicateRecordIds ?? this.confirmedDuplicateRecordIds,
    );
  }
}

class ImportResult {
  const ImportResult({
    required this.imported,
    required this.duplicates,
    required this.skipped,
    required this.failed,
    this.cacheRepairPending = false,
  });

  final int imported;
  final int duplicates;

  /// Rows deliberately quarantined because importing them would corrupt their
  /// meaning. Currently this is a contribution whose exported currency does
  /// not match the currency of its effective parent goal.
  final int skipped;
  final int failed;
  final bool cacheRepairPending;
}

abstract interface class DataPortabilityService {
  Future<ExportedFile> exportTransactionsCsv();

  Future<ExportedFile> exportFinancialPackage();

  Future<ImportPreview> inspectFile(String path);

  Future<ImportResult> import(ImportPreview preview, ImportMode mode);
}

class DataPortabilityException implements Exception {
  const DataPortabilityException(this.message);

  final String message;

  @override
  String toString() => message;
}
