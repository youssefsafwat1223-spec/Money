import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Release-closure guards for the affiliate track.
///
/// What remains here is deliberately SOURCE-level, because the properties are
/// source-level: "no affiliate code path may reach the savings ledger" and "the
/// flag ships seeded OFF" are claims about what the code contains, and no
/// runtime test can prove the absence of a path it did not happen to take.
///
/// The CTA wiring, the https check and the consent gate used to be pinned this
/// way too, and should not have been — those are runtime behaviours. They now
/// live in affiliate_cta_behaviour_test.dart.
void main() {
  String read(String p) => File(p).readAsStringSync();

  group('a click is never a financial claim', () {
    test('the affiliate gateway does not touch the savings ledger', () {
      // Savings in this app are a USER SELF-REPORTED local ledger
      // (savings_confirm_sheet), not something derived from a provider
      // conversion. Nothing on the affiliate path may create one: a click is an
      // intent to visit a merchant, and even a confirmed conversion is a
      // commission record, not a user's saving.
      final gateway = read('lib/features/coupons/affiliate_click_gateway.dart');
      for (final forbidden in [
        'local_offer_savings',
        'SavingsRepository',
        'savingsRepositoryProvider',
      ]) {
        expect(gateway.contains(forbidden), isFalse,
            reason: 'the click gateway must not reach the savings ledger '
                '($forbidden)');
      }
    });

    test('the gateway writes only to its own receipt table', () {
      final gateway = read('lib/features/coupons/affiliate_click_gateway.dart');
      final writes = RegExp(r'INSERT INTO (\w+)')
          .allMatches(gateway)
          .map((m) => m.group(1))
          .toSet();
      expect(writes, {'affiliate_click_receipts'},
          reason: 'a click may record a claim token and nothing else');
    });
  });

  group('the feature stays off until deliberately enabled', () {
    test('enable_affiliate_links is seeded OFF', () {
      final flags = read('lib/data/catalog/feature_flag_service.dart');
      expect(flags, contains("'enable_affiliate_links': false"));
    });
  });

  // The CTA wiring, the https check and the consent gate used to be pinned
  // here by reading the source and matching symbol names — a guard that passed
  // whether or not the CTA actually launched what the gateway returned. They
  // are now asserted behaviourally, at the platform-launcher boundary and
  // through the real provider, in affiliate_cta_behaviour_test.dart.
}
