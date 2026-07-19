import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/data_portability/data_portability_models.dart';
import 'package:money_companion/core/data_portability/import_normalizer.dart';

void main() {
  group('ImportNormalizer', () {
    test('normalizes account types correctly', () {
      final rawAccounts = [
        {'type': 'CASH', 'is_default': '1'},
        {'type': 'unknown_type', 'is_default': 'true'},
      ];

      final normalized = ImportNormalizer.normalize(
        {'accounts': rawAccounts},
        ImportMode.replace,
      );

      final accounts = normalized['accounts']!;
      expect(accounts[0]['type'], 'cash');
      expect(accounts[1]['type'], 'bank'); // fallback
    });

    test('enforces single default account in replace mode', () {
      final rawAccounts = [
        {'id': '1', 'is_default': 'true'},
        {'id': '2', 'is_default': '1'},
        {'id': '3', 'is_default': 'false'},
      ];

      final normalized = ImportNormalizer.normalize(
        {'accounts': rawAccounts},
        ImportMode.replace,
      );

      final accounts = normalized['accounts']!;
      expect(accounts[0]['is_default'], 'true');
      expect(accounts[1]['is_default'], 'false'); // stripped
      expect(accounts[2]['is_default'], 'false');
    });

    test('strips all default accounts in merge mode', () {
      final rawAccounts = [
        {'id': '1', 'is_default': 'true'},
        {'id': '2', 'is_default': '1'},
      ];

      final normalized = ImportNormalizer.normalize(
        {'accounts': rawAccounts},
        ImportMode.merge,
      );

      final accounts = normalized['accounts']!;
      expect(accounts[0]['is_default'], 'false');
      expect(accounts[1]['is_default'], 'false');
    });

    test('normalizes transaction legacy enums and sets safe defaults', () {
      final rawTransactions = [
        {
          'direction': 'DEBIT ',
          'type': 'payment', // legacy type
          'status': 'invalid_status',
          'source': 'unknown_source',
          'comparison_timestamp_source': 'occurred_at', // invalid source
          'foreign_amount': '-5.0', // invalid negative foreign amount
        },
        {
          'type': 'transfer',
          'comparison_timestamp_source': 'sms_body',
          'foreign_amount': '50.0',
          'foreign_currency': 'USD',
        }
      ];

      final normalized = ImportNormalizer.normalize(
        {'transactions': rawTransactions},
        ImportMode.replace,
      );

      final transactions = normalized['transactions']!;

      expect(transactions[0]['direction'], 'debit');
      expect(transactions[0]['transaction_type'],
          'expense'); // mapped from 'payment'
      expect(transactions[0]['status'], 'confirmed'); // fallback
      expect(transactions[0]['source'], 'import'); // fallback
      expect(transactions[0]['comparison_timestamp_source'],
          'received_at'); // fallback
      expect(transactions[0].containsKey('foreign_amount'),
          isFalse); // stripped because <= 0

      expect(transactions[1]['transaction_type'], 'transfer');
      expect(transactions[1]['comparison_timestamp_source'],
          'sms_body'); // kept valid
      expect(transactions[1]['foreign_amount'], '50.0'); // kept valid
      expect(transactions[1]['foreign_currency'], 'USD'); // kept valid
    });
  });
}
