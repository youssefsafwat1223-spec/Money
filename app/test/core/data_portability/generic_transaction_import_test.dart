import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/data_portability/data_portability_models.dart';
import 'package:money_companion/core/data_portability/generic_transaction_import.dart';
import 'package:money_companion/core/data_portability/portable_csv.dart';
import 'package:money_companion/domain/finance/money.dart';

void main() {
  test('parses Arabic digits, grouping, decimal marker and debit direction', () {
    const document = PortableCsvDocument(
      headers: ['التاريخ', 'المبلغ', 'العملة', 'الوصف'],
      rows: [
        {
          'التاريخ': '١٨/٠٧/٢٠٢٦',
          'المبلغ': '-١٬٢٥٠٫٥٠',
          'العملة': 'egp',
          'الوصف': 'متجر',
        },
      ],
    );
    const mapping = CsvColumnMapping(
      dateColumn: 'التاريخ',
      amountColumn: 'المبلغ',
      currencyColumn: 'العملة',
      merchantColumn: 'الوصف',
      dateFormat: ImportDateFormat.dayMonthYear,
    );
    final result = parseGenericTransactions(
      document: document,
      mapping: mapping,
      defaultCurrency: 'SAR',
    );

    expect(result.issues, isEmpty);
    expect(result.records.single.amountMoney, Money.parse('1250.50', 'EGP'));
    expect(result.records.single.amount, 1250.5);
    expect(result.records.single.currency, 'EGP');
    expect(result.records.single.direction, ImportedDirection.expense);
  });

  test('rejects an ambiguous comma instead of changing its magnitude', () {
    const document = PortableCsvDocument(
      headers: ['date', 'amount'],
      rows: [
        {'date': '2026-07-18', 'amount': '12,50'},
      ],
    );
    const mapping = CsvColumnMapping(
      dateColumn: 'date',
      amountColumn: 'amount',
    );

    final result = parseGenericTransactions(
      document: document,
      mapping: mapping,
      defaultCurrency: 'EGP',
    );

    expect(result.records, isEmpty);
    expect(result.issues, hasLength(1));
  });

  test('supports separate debit and credit columns', () {
    const document = PortableCsvDocument(
      headers: ['date', 'amount', 'debit', 'credit'],
      rows: [
        {
          'date': '2026-07-18T12:00:00Z',
          'amount': '',
          'debit': '',
          'credit': '500',
        },
      ],
    );
    const mapping = CsvColumnMapping(
      dateColumn: 'date',
      amountColumn: 'amount',
      debitColumn: 'debit',
      creditColumn: 'credit',
    );
    final result = parseGenericTransactions(
      document: document,
      mapping: mapping,
      defaultCurrency: 'SAR',
    );
    expect(result.records.single.direction, ImportedDirection.income);
  });

  test('same normalized row receives a stable id', () {
    const document = PortableCsvDocument(
      headers: ['date', 'amount'],
      rows: [
        {'date': '2026-07-18', 'amount': '-20'},
      ],
    );
    const mapping = CsvColumnMapping(
      dateColumn: 'date',
      amountColumn: 'amount',
    );
    final first = parseGenericTransactions(
      document: document,
      mapping: mapping,
      defaultCurrency: 'EGP',
    );
    final second = parseGenericTransactions(
      document: document,
      mapping: mapping,
      defaultCurrency: 'EGP',
    );
    expect(first.records.single.recordId, second.records.single.recordId);
  });

  test('invalid rows are reported without blocking valid rows', () {
    const document = PortableCsvDocument(
      headers: ['date', 'amount'],
      rows: [
        {'date': 'bad', 'amount': '20'},
        {'date': '2026-07-18', 'amount': '-30'},
      ],
    );
    const mapping = CsvColumnMapping(
      dateColumn: 'date',
      amountColumn: 'amount',
    );
    final result = parseGenericTransactions(
      document: document,
      mapping: mapping,
      defaultCurrency: 'EGP',
    );
    expect(result.issues.single.rowNumber, 2);
    expect(result.records, hasLength(1));
  });
}
