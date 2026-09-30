import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Merchant enrichment (`enrich-merchant`) sends a name derived from a
/// financial message to the cloud. Both construction sites of
/// AddTransactionUseCase that wire a resolver must also wire the consent
/// callback, or the use case fails closed and enrichment silently dies.
void main() {
  for (final path in const [
    'lib/core/di/app_providers.dart',
    'lib/features/capture/services/captured_message_processor.dart',
  ]) {
    test('$path wires mayEnrichMerchant to financialSync consent', () {
      final src = File(path).readAsStringSync();
      final at = src.indexOf('mayEnrichMerchant:');
      expect(at, isNonNegative, reason: 'mayEnrichMerchant not wired');
      final window = src.substring(at, at + 250);
      expect(window, contains('ConsentAuthority('));
      expect(window, contains('EgressClass.financialSync'));
    });
  }

  test('use case is the choke point: fails closed without the callback', () {
    final src = File('lib/domain/usecases/add_transaction_usecase.dart')
        .readAsStringSync();
    expect(src, contains('_mayEnrichMerchantNow()'));
    expect(src, contains('if (check == null) return false;'));
  });
}
