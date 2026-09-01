/// Rev-5 `totalDueRules` — deterministic evidence, NOT a ranking heuristic.
///
/// A credit-card statement carries both the purchase and the outstanding
/// balance:
///
///     شراء عبر نقاط البيع بـ SAR 150.00
///     المبلغ الإجمالي المستحق SAR 5620.87
///
/// Both are monetary, so the fail-closed gate sends the message to REVIEW. The
/// second number is not the transaction, and a bank profile already says so —
/// `bsf.totalDueRules` contains `المبلغ الإجمالي المستحق`. Reading a rule the
/// app already ships is deterministic evidence.
///
/// The danger is that this becomes a back door for "the biggest number loses"
/// or "the last number loses". It must not. The tests below therefore spend
/// more effort proving what does NOT exclude a number than proving what does:
///
///   · a profile with no totalDueRules excludes nothing;
///   · the bare words total / due / الإجمالي / المستحق exclude nothing;
///   · position in the message excludes nothing;
///   · a rule cannot reach past one number to claim another.
///
/// If no deterministic rule applies, the ambiguity stands and the message goes
/// to REVIEW. That is the intended outcome, not a gap.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/models/transaction_type.dart';
import 'package:money_companion/engine/parser/bank_profile.dart';
import 'package:money_companion/engine/proof/amount_candidates.dart';
import 'package:money_companion/engine/proof/evidence.dart';

BankProfile _profile(List<String> totalDueRules) => BankProfile(
      bankKey: 'testbank',
      displayName: 'Test',
      keywords: const [],
      senderIds: const [],
      currencyAliases: const {},
      ignoreRules: const [],
      typeRules: const <TransactionType, List<String>>{},
      amountRules: const [],
      balanceRules: const [],
      feeRules: const [],
      totalDueRules: totalDueRules,
      merchantRules: const [],
      dateRules: const [],
    );

Set<String> candidates(String sms, {BankProfile? bank}) =>
    amountCandidates(extractEvidence(sms), bank: bank)
        .map((e) => e.text)
        .toSet();

const _statement = 'شراء عبر نقاط البيع بـ SAR 150.00\n'
    'المبلغ الإجمالي المستحق SAR 5620.87\n'
    'الرصيد المتوفر: SAR 14379.13';

void main() {
  group('a declared rule establishes total_due', () {
    test('the real bsf rule resolves the statement to one candidate', () {
      final bank = _profile(const ['المبلغ الإجمالي المستحق']);
      expect(candidates(_statement, bank: bank), equals({'150.00'}));
    });

    test('the exclusion carries provenance naming the rule', () {
      final bank = _profile(const ['المبلغ الإجمالي المستحق']);
      final ev = extractEvidence(_statement);
      final excluded = totalDueExclusions(ev, bank);
      expect(excluded, isNotEmpty);
      final provenance = excluded.values.first;
      expect(provenance, contains('testbank'));
      expect(provenance, contains('المبلغ الإجمالي المستحق'));
    });
  });

  group('what must NOT exclude a number', () {
    test('no bank profile at all excludes nothing', () {
      expect(candidates(_statement), containsAll(<String>['150.00', '5620.87']),
          reason: 'without a rule the ambiguity must stand');
    });

    test('a profile with no totalDueRules excludes nothing', () {
      expect(candidates(_statement, bank: _profile(const [])),
          containsAll(<String>['150.00', '5620.87']));
    });

    test('a rule for a DIFFERENT phrase excludes nothing', () {
      final bank = _profile(const ['الحد الائتماني']);
      expect(candidates(_statement, bank: bank),
          containsAll(<String>['150.00', '5620.87']));
    });

    test('the bare word total does not exclude', () {
      final bank = _profile(const ['المبلغ الإجمالي المستحق']);
      // `Total charged` is the authoritative amount and must survive.
      expect(candidates('Total charged AED 47.25', bank: bank),
          equals({'47.25'}));
    });

    test('the bare word due does not exclude', () {
      final bank = _profile(const ['المبلغ الإجمالي المستحق']);
      expect(candidates('Payment due SAR 90.00', bank: bank),
          equals({'90.00'}));
    });

    test('position in the message does not exclude', () {
      // Largest-last and largest-wins would both fire here. Neither may.
      final bank = _profile(const ['المبلغ الإجمالي المستحق']);
      final c = candidates('خصم 120.00 ر.س وخصم 9,999.00 ر.س', bank: bank);
      expect(c, containsAll(<String>['120.00', '9,999.00']),
          reason: 'two real amounts stay ambiguous — no ranking rule exists');
    });

    test('a rule cannot reach past one number to claim another', () {
      final bank = _profile(const ['المبلغ الإجمالي المستحق']);
      const sms = 'المبلغ الإجمالي المستحق SAR 500.00 ثم مبلغ SAR 20.00';
      final c = candidates(sms, bank: bank);
      expect(c, contains('20.00'),
          reason: 'only the nearest number after the rule is claimed');
      expect(c, isNot(contains('500.00')));
    });
  });

  group('the fail-closed default is preserved', () {
    test('an FX pair stays ambiguous even with a totalDue profile', () {
      // Deferred by ruling: which FX leg is the ledger amount is an accounting
      // decision, not something this rule may quietly settle.
      final bank = _profile(const ['المبلغ الإجمالي المستحق']);
      expect(candidates('Amount: USD 4.91 (SAR 18.44)', bank: bank).length,
          greaterThan(1));
    });
  });
}
