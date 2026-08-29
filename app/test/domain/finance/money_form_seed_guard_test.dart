import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/finance/money_input.dart';

/// Cross-model audit finding **C-1** — money edit forms silently rewrote the
/// stored amount.
///
/// Every money form seeds a `TextEditingController` from the existing entity and
/// then parses that same text back into `Money` on save. Seeding from a ROUNDED
/// display double therefore rewrites the persisted amount even when the user
/// never touches the field:
///
///   budget 1500.50 SAR → `toStringAsFixed(0)` → "1501" → stored 150100 minor
///   bill   12.345 KWD  → `toStringAsFixed(2)` → "12.35" → stored 12350 minor
///
/// The existing `money_write_path_guard_test` could not see this: the final
/// write *is* a legitimate exact `Money`, and the corruption happened upstream
/// in presentation text. These guards close that band.
Directory _libRoot() {
  final direct = Directory('lib');
  if (direct.existsSync()) return direct;
  final nested = Directory('app/lib');
  if (nested.existsSync()) return nested;
  throw StateError('money-form guard could not locate lib/');
}

String _relativePath(File file) {
  final normalized = file.path.replaceAll('\\', '/');
  final marker = normalized.lastIndexOf('/lib/');
  return marker < 0 ? normalized : normalized.substring(marker + 1);
}

List<File> _productionDartFiles() => _libRoot()
    .listSync(recursive: true)
    .whereType<File>()
    .where(
        (file) => file.path.endsWith('.dart') && !file.path.endsWith('.g.dart'))
    .toList(growable: false);

/// Display-only doubles that entities expose purely for presentation. Each is
/// documented in its entity as "never a write/persisted-calc source".
const _moneyDisplayGetters = <String>{
  'amount',
  'targetAmount',
  'savedAmount',
  'autoSaveAmount',
  'budgetAmount',
  'manualPaidAmount',
  'totalPurchaseAmount',
  'lastNotifiedSpentAmount',
  'lastNotifiedSavedAmount',
  'initialBalance',
  'currentBalance',
  'creditLimit',
  'availableCredit',
  'balanceAfter',
  'foreignAmount',
  'remainingAmount',
};

/// Controller seeds that are deliberately NOT money and may round freely.
/// Keyed by a distinctive substring of the offending statement.
const _nonMoneyControllerSeeds = <String>{
  'interestRate', // a percentage rate, not a money column
};

void main() {
  group('C-1 — money controllers are seeded from canonical Money', () {
    test('no TextEditingController is seeded from a rounded money double', () {
      final violations = <String>[];
      for (final file in _productionDartFiles()) {
        final source = file.readAsStringSync();
        if (!source.contains('toStringAsFixed')) continue;

        // Statement-scoped: a seed is a single statement that both touches a
        // controller and rounds. This deliberately ignores display formatting
        // (labels, chart axes), which is never re-parsed.
        for (final statement in source.split(';')) {
          if (!statement.contains('toStringAsFixed')) continue;
          if (!statement.contains('Controller')) continue;
          if (_nonMoneyControllerSeeds.any(statement.contains)) continue;

          final touchesMoney = _moneyDisplayGetters.any(
            (getter) => RegExp(r'\.' + getter + r'\b').hasMatch(statement),
          );
          if (!touchesMoney) continue;

          final line = '\n'
                  .allMatches(source.substring(0, source.indexOf(statement)))
                  .length +
              1;
          violations.add(
              '${_relativePath(file)}:~$line ${statement.trim().replaceAll(RegExp(r'\s+'), ' ')}');
        }
      }

      expect(
        violations,
        isEmpty,
        reason: 'money controllers must be seeded from '
            '`<entity>.<field>Money.toDecimalString()`, never a rounded display '
            'double — the text is parsed straight back into Money on save '
            '(audit C-1):\n${violations.join('\n')}',
      );
    });

    test('the repaired seeds use the canonical accessor', () {
      // Positive proof: deleting a fix must fail here, not merely stop being
      // caught by the negative guard above.
      const expected = <String, String>{
        'lib/features/budgets/budget_form_screen.dart':
            'budget.amountMoney.toDecimalString()',
        'lib/features/goals/goal_form_screen.dart':
            'goal.targetMoney.toDecimalString()',
        'lib/features/plans/plan_form_sheet.dart':
            'e.budgetAmountMoney.toDecimalString()',
        'lib/features/subscriptions/bill_form_sheet.dart':
            'bill.amountMoney.toDecimalString()',
        'lib/features/subscriptions/bill_details_sheet.dart':
            'bill.amountMoney.toDecimalString()',
      };
      for (final entry in expected.entries) {
        final file = File('${_libRoot().path}/${entry.key.substring(4)}');
        expect(file.existsSync(), isTrue, reason: 'missing ${entry.key}');
        expect(file.readAsStringSync(), contains(entry.value),
            reason: '${entry.key} must seed from canonical Money');
      }
    });

    test('the account form handles every persisted money field canonically',
        () {
      final file = File(
        '${_libRoot().path}/features/accounts/account_form_sheet.dart',
      );
      expect(file.existsSync(), isTrue, reason: 'missing account form');

      final source = file.readAsStringSync();
      const expectedHandling = <String, String>{
        'initial_balance': 'a?.initialBalanceMoney?.toDecimalString()',
        'current_balance': ': widget.account?.currentBalanceMoney,',
        'credit_limit': 'a?.creditLimitMoney?.toDecimalString()',
        'available_credit': 'a?.availableCreditMoney?.toDecimalString()',
      };
      for (final entry in expectedHandling.entries) {
        expect(
          source,
          contains(entry.value),
          reason: 'persisted account money field ${entry.key} must use its '
              'canonical Money value on an untouched save',
        );
      }
      expect(source, contains('currentBalanceMoney: currencyChanged'),
          reason: 'current balance handling must distinguish a currency edit');
      expect(source, contains('Money.zero(submittedCurrency)'),
          reason: 'an empty-account currency edit must recreate zero in the '
              'new currency rather than carry Money across currencies');
    });
  });

  group('C-1 — seed text round-trips exactly', () {
    // The property the fix depends on: whatever a form seeds must parse back
    // to the identical Money, or an untouched Save still corrupts the row.
    void roundTrips(int minorUnits, String currency) {
      final original = Money(minorUnits, currency);
      final reparsed =
          parseLocalizedMoney(original.toDecimalString(), currency);
      expect(reparsed.minorUnits, original.minorUnits,
          reason: '${original.toDecimalString()} $currency did not round-trip');
      expect(reparsed.currency, original.currency);
    }

    test('2-decimal currencies survive an untouched edit', () {
      roundTrips(150050, 'SAR'); // 1500.50 — the reported budget case
      roundTrips(499950, 'SAR'); // 4999.50 — the installment case
      roundTrips(1200075, 'SAR'); // 12000.75 — the goal case
      roundTrips(850040, 'SAR'); // 8500.40 — the plan case
      roundTrips(1, 'USD'); // smallest representable unit
    });

    test('3-decimal currencies keep their third digit', () {
      roundTrips(12345, 'KWD'); // 12.345 — silently became 12.350
      roundTrips(86415, 'KWD'); // 86.415 — the "pay all remaining" case
      roundTrips(1, 'BHD');
      roundTrips(999, 'OMR');
    });

    test('0-decimal currencies gain no phantom fraction', () {
      roundTrips(1000, 'JPY');
      roundTrips(4500, 'KMF');
    });

    test('negative and large values survive', () {
      roundTrips(-150050, 'SAR');
      roundTrips(
          9007199254740993, 'SAR'); // beyond 2^53 — exact via minor units
    });

    test('all account money fields survive an untouched save exactly', () {
      final accountMoney = <String, Money>{
        'initialBalanceMoney': Money(-9007199254740993, 'SAR'),
        'currentBalanceMoney': Money(9007199254740993, 'KWD'),
        'creditLimitMoney': Money(9007199254740993, 'KWD'),
        'availableCreditMoney': Money(12345, 'BHD'),
      };

      for (final entry in accountMoney.entries) {
        final original = entry.value;
        final seed = original.toDecimalString();
        final reparsed = parseLocalizedMoney(seed, original.currency);
        expect(
          reparsed,
          original,
          reason: '${entry.key} changed after canonical seed→parse',
        );
      }
    });
  });
}
