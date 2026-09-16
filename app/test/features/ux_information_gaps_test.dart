import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// UX-007 and UX-023 — two findings the QA classed as INFORMATION gaps rather
/// than styling. Both had correct data and a label that did not describe it, so
/// both are asserted against the source of the surface that renders them.
void main() {
  group('UX-007 — the Home chip names the active account', () {
    final source =
        File('lib/features/dashboard/dashboard_screen.dart').readAsStringSync();

    test('the label is built from the account name', () {
      expect(source, contains(r'${selected.name}'),
          reason: 'the chip read «حساب ريال» for every riyal account, so '
              'switching accounts changed every headline figure on Home while '
              'the chip said the same thing');
    });

    test('the currency-only label is gone', () {
      expect(source.contains(r"'حساب ${_currencyLabel(selected.currency)}'"),
          isFalse,
          reason: 'describing the currency is what made two different accounts '
              'indistinguishable');
    });

    test('the correct implementation is the one that is MOUNTED', () {
      // A version that names the account already existed in
      // account_range_controls.dart — and was never mounted anywhere. Fixing
      // the dead copy would have changed nothing on screen, so the test is
      // anchored to the widget the dashboard actually builds.
      final dead = File('lib/features/common/account_range_controls.dart')
          .readAsStringSync();
      expect(dead, contains('account.name'),
          reason: 'unmounted control, kept for reference');
      expect(source, contains('GlassSelector'),
          reason: 'the dashboard builds its own chip — this is the live one');
    });
  });

  group('UX-023 — the subscriptions metric is named for what it measures', () {
    final source = File('lib/features/subscriptions/subscriptions_screen.dart')
        .readAsStringSync();

    test('the header no longer claims to be a total', () {
      expect(source.contains("subtitle: 'إجمالي الصرف الشهري'"), isFalse,
          reason: 'it measured active subscriptions only, while the counters '
              'beneath it also announced installments');
      // UX-024 later made this conditional — the subtitle now also names the
      // account the list is scoped to — so both branches are asserted. The
      // copy lives in the ARB now, so the claim is checked in BOTH languages:
      // an English header that still said "total" would be the same defect.
      expect(source, contains('context.l10n.subsMonthlyTotal'));
      expect(source, contains('context.l10n.subsMonthlyScoped(scopeAccountName!)'));
      expect(_arb('ar')['subsMonthlyTotal'], 'الاشتراكات الشهرية');
      expect(_arb('ar')['subsMonthlyScoped'], 'الاشتراكات الشهرية · {account}');
      expect(_arb('en')['subsMonthlyTotal'], 'Monthly subscriptions');
      expect(_arb('en')['subsMonthlyScoped'], 'Monthly subscriptions · {account}');
      for (final lang in ['ar', 'en']) {
        expect(_arb(lang)['subsMonthlyTotal'],
            isNot(anyOf(contains('إجمالي'), contains('Total'))),
            reason: 'naming it a total is the defect UX-023 recorded');
      }
    });

    test('the calculation is untouched', () {
      // The QA was explicit: fix the label, not the maths. Excluding a finite
      // installment from an open-ended subscription metric is defensible and
      // documented (MALI-064n).
      expect(source, contains('subscriptionMonthlyTotalMoney(subs, baseCur)'),
          reason: 'the canonical metric must remain the canonical metric');
    });

    test('the installment obligation is surfaced as its own line', () {
      expect(source, contains('installmentMonthly'));
      expect(source, contains('context.l10n.subsMonthlyInstCommit'));
      expect(_arb('ar')['subsMonthlyInstCommit'], 'التزام الأقساط شهريًا');
      expect(_arb('en')['subsMonthlyInstCommit'],
          'Monthly instalment commitment');
    });

    test('the installment total filters to ACTIVE explicitly', () {
      // `monthlyEquivalentsTotalMoney` is deliberately filter-free ("the caller
      // decides"), which is exactly the footgun that produced F-027 when a
      // caller forgot. The filter must be visible at the call site.
      expect(
        source,
        contains('insts.where((b) => b.status == BillStatus.active)'),
        reason: 'an unfiltered call would count cancelled installments as a '
            'live monthly obligation',
      );
    });

    test('the new figure is rendered as exact Money', () {
      expect(source, contains('formatMoney(installmentMonthly)'),
          reason: 'R-8: a money figure must not be added through a double');
    });
  });
}

Map<String, dynamic> _arb(String lang) =>
    jsonDecode(File('lib/l10n/app_$lang.arb').readAsStringSync())
        as Map<String, dynamic>;
