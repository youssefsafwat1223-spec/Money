import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/finance/money.dart';

/// A form must not rewrite money the user did not touch.
///
/// The budget, goal and plan edit forms seed their amount field from the entity,
/// and `_save()` parses that field straight back into `Money`. So whatever the
/// field is seeded WITH becomes the stored value the moment the user presses
/// Save — even if they changed nothing.
///
/// The seed used `amount.toStringAsFixed(0)`: the display double, rounded to
/// ZERO decimals. Open a 1500.50 budget, press Save without touching it, and it
/// silently becomes 1501.00. No error, no warning, no indication anything
/// changed — and the user has no reason to re-check a form they did not edit.
///
/// This is asserted two ways, because each alone would miss something:
///  * arithmetically, that the round trip through the seed loses value;
///  * structurally, that no form seeds from `toStringAsFixed` on a money field,
///    which is what stops the pattern returning in the next form someone writes.
void main() {
  const forms = <String>[
    'lib/features/budgets/budget_form_screen.dart',
    'lib/features/goals/goal_form_screen.dart',
    'lib/features/plans/plan_form_sheet.dart',
  ];

  group('the round trip a Save performs', () {
    test('seeding from a rounded display string loses the real amount', () {
      // Exactly what the defect did, in isolation: this is the arithmetic the
      // form performed on a no-op Save.
      final stored = Money.parse('1500.50', 'SAR');
      final seededTheOldWay = stored.toDouble().toStringAsFixed(0); // "1501"
      final reparsed = Money.parse(seededTheOldWay, 'SAR');

      expect(reparsed, isNot(stored),
          reason: 'this is the silent mutation: 1500.50 became '
              '${reparsed.toDecimalString()} without the user editing anything');
      expect(reparsed.minorUnits, 150100);
      expect(stored.minorUnits, 150050);
    });

    test('seeding from the canonical decimal string round-trips exactly', () {
      // The fix, asserted as a property rather than a spot value.
      for (final entry in const {
        'SAR': ['1500.50', '0.01', '999999.99', '0'],
        'KWD': ['12.345', '0.001'], // 3-decimal currency
        'JPY': ['1500'], // 0-decimal currency
      }.entries) {
        for (final decimal in entry.value) {
          final stored = Money.parse(decimal, entry.key);
          final reparsed =
              Money.parse(stored.toDecimalString(), entry.key);
          expect(reparsed, stored,
              reason: '$decimal ${entry.key} did not survive the seed→save '
                  'round trip');
        }
      }
    });

    test('the loss is worst exactly where money matters most', () {
      // A 3-decimal currency loses more: 12.345 KWD seeded at 0 decimals is 12,
      // a 345-fils error on a single edit.
      final kwd = Money.parse('12.345', 'KWD');
      final oldSeed = Money.parse(kwd.toDouble().toStringAsFixed(0), 'KWD');
      expect(oldSeed.minorUnits, isNot(kwd.minorUnits));
      expect((oldSeed.minorUnits - kwd.minorUnits).abs(), greaterThan(300));
    });
  });

  group('no form re-introduces the pattern', () {
    test('no money field is seeded through toStringAsFixed', () {
      // The structural half. Fixing three files does not stop a fourth form
      // from being written the same way, and the failure is invisible in
      // testing because it only shows up as a slightly different stored number.
      for (final path in forms) {
        final src = File(path).readAsStringSync();
        final offenders = RegExp(r'\.text\s*=\s*[^;]*toStringAsFixed')
            .allMatches(src)
            .map((m) => m.group(0))
            .toList();
        expect(offenders, isEmpty,
            reason: '$path seeds a text field via toStringAsFixed:\n'
                '  ${offenders.join('\n  ')}\n'
                'Seed from the canonical Money (toDecimalString) — the value '
                'seeded here is what Save stores.');
      }
    });

    test('each form seeds from canonical money', () {
      for (final path in forms) {
        final src = File(path).readAsStringSync();
        expect(src, contains('toDecimalString'),
            reason: '$path must seed its amount field from canonical Money');
      }
    });
  });
}
