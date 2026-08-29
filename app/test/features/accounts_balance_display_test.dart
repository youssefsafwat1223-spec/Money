import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// UX-013 — «how much money do I have?» must be answerable.
///
/// The Accounts screen listed name + type + currency and nothing else. The
/// balances existed on `AccountEntity.currentBalanceMoney` and were correct;
/// they were simply never rendered. Home shows *expenses* rather than a balance,
/// so no screen in the app answered the first question any user asks.
///
/// Structural rather than golden: the finding is "the balance is absent from
/// this screen", which is a property of the source, and a pixel test would fail
/// on unrelated styling while still passing if the balance were removed.
void main() {
  final source =
      File('lib/features/accounts/accounts_screen.dart').readAsStringSync();

  test('each account card renders its balance', () {
    expect(source, contains('currentBalanceMoney'),
        reason: 'the balance is on the entity and must reach the card');
    expect(source, contains('MoneyText('),
        reason: 'money must go through the exact formatter, not toString');
  });

  test('the balance is not rendered through a double', () {
    // R-8: `Money.toDouble()` is approximate past 2^53 and is what UX-035
    // reports. A balance is the most checkable number in the app.
    expect(source.contains('currentBalance.toDouble()'), isFalse);
    expect(source.contains('.currentBalance)'), isFalse,
        reason: 'use the Money-typed field, not the double convenience getter');
  });

  test('a negative balance is visually distinguished', () {
    // Normal for a credit card, so it is coloured as information rather than as
    // an error — but it must never read as a positive figure. MoneyText keeps
    // the sign attached; this asserts the colour branch exists.
    expect(source, contains('minorUnits < 0'),
        reason: 'negative balances need an explicit visual treatment');
  });

  group('totals are grouped BY CURRENCY, never summed across', () {
    test('the totals widget keys by currency', () {
      expect(source, contains('_CurrencyTotals'));
      expect(source, contains('totals[m.currency]'),
          reason: 'a single cross-currency total would violate the '
              'financial-semantics contract — there is no FX layer, so summing '
              'SAR and EGP produces a number that means nothing');
    });

    test('no cross-currency accumulation appears', () {
      // The specific mistake this guards: folding every account into one sum.
      expect(source.contains('fold<double>'), isFalse);
      expect(source.contains('accounts.fold'), isFalse);
    });

    test('totals accumulate in minor units, not doubles', () {
      expect(source, contains('m.minorUnits'),
          reason: 'summing formatted or double values reintroduces drift');
    });
  });
}
