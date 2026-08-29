import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/engagement_entities.dart';
import 'package:money_companion/domain/finance/hero_amount_size.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/finance/money_format.dart';
import 'package:money_companion/domain/services/budget_alert_planner.dart';
import 'package:money_companion/features/capture/services/capture_notification_content.dart';

/// Phase J — the batch of findings whose common shape is *"the data was there
/// and the screen did not say it"*, plus the two destructive/notification
/// safety ones.
///
/// Structural where the finding is a property of a surface's source, and
/// behavioural where a value can actually be computed.
void main() {
  group('UX-001 — a budget card can no longer contradict itself', () {
    // The reported card: limit 1,200, spend 355.50. Rounding spend and
    // remaining independently printed «356» and «845» — 1,201 against a limit
    // of 1,200, wrong by a riyal and visible in one glance.
    final limit = Money(120000, 'SAR');
    final spent = Money(35550, 'SAR');
    final remaining = limit - spent;

    test('the three figures reconcile exactly', () {
      expect(spent + remaining, limit);
      expect(formatMoney(spent), '355.50');
      expect(formatMoney(remaining), '844.50');
      expect(formatMoney(limit), '1,200.00');
    });

    test('the OLD rounding is what produced the contradiction', () {
      // Kept as the reproduction: this is the arithmetic the screen used to do,
      // and it is why "just round consistently" was not a fix.
      final roundedSpent = (spent.minorUnits / 100).round();
      final roundedRemaining = (remaining.minorUnits / 100).round();
      expect(roundedSpent + roundedRemaining, 1201);
      expect(roundedSpent + roundedRemaining, isNot(1200));
    });

    test('بقالة reconciled only by luck, not by rule', () {
      // 1,644.30 spent against 2,500.00 — rounds the other way and happens to
      // add up. A rule that is right half the time is the defect.
      final b = Money(164430, 'SAR');
      final bLimit = Money(250000, 'SAR');
      final bRemaining = bLimit - b;
      expect((b.minorUnits / 100).round() + (bRemaining.minorUnits / 100).round(),
          2500);
    });

    final screen =
        File('lib/features/budgets/budgets_screen.dart').readAsStringSync();

    test('the amount tile takes Money, so a caller cannot round on the way in',
        () {
      expect(screen, contains('final Money amount;'));
      expect(screen, contains('MoneyText(\n          amount,'));
    });

    test('no budget figure is formatted through an integer rounding', () {
      expect(screen.contains('Formatters.integer(entry.spent'), isFalse);
      expect(screen.contains('Formatters.integer(entry.remaining'), isFalse);
      expect(screen.contains('Formatters.integer((-entry.remaining)'), isFalse);
    });

    test('the limit tile reads the exact field, not the legacy REAL one', () {
      expect(screen, contains('amount: entry.budget.amountMoney'));
      expect(screen.contains('Formatters.integer(entry.budget.amount)'), isFalse);
    });
  });

  group('UX-035 — large values keep their digits and stay legible', () {
    test('an amount past 2^53 is exact, where a double is not', () {
      // The literal form of "silently rounding": a double cannot represent
      // consecutive integers this large, so the digits printed were not the
      // digits stored.
      final huge = Money(9007199254740993, 'SAR');
      expect(formatMoney(huge), '90,071,992,547,409.93');
      expect(huge.toDouble().toStringAsFixed(2),
          isNot(equals('90071992547409.93')),
          reason: 'the double path is what the finding describes');
    });

    test('the hero has a legibility floor rather than shrinking to nothing',
        () {
      expect(heroAmountFontSize('12,345.67'.length), 40);
      expect(heroAmountFontSize('1,234,567.89'.length), lessThan(40));
      expect(heroAmountFontSize('1,234,567,890.12'.length),
          lessThan(heroAmountFontSize('1,234,567.89'.length)));
    });

    test('the floor holds no matter how long the value gets', () {
      final absurd = formatMoney(Money(1 << 62, 'SAR'));
      expect(heroAmountFontSize(absurd.length), greaterThanOrEqualTo(40 * 0.55),
          reason: 'a size that keeps shrinking is the «0 0 0» the QA reported');
    });
  });

  group('UX-037 — a budget alert says which budget crossed which threshold',
      () {
    BudgetAlertContent? plan({String? account}) {
      final budget = BudgetEntity(
        id: 'b1',
        categoryId: 'shopping',
        amountMoney: Money(100000, 'SAR'),
        lastNotifiedSpentMoney: Money.zero('SAR'),
        currency: 'SAR',
        period: BudgetPeriod.monthly,
        startDate: DateTime.utc(2026, 8, 1),
        isActive: true,
        lastNotifiedPeriodStart: DateTime.utc(2026, 8, 1),
        accountId: 'a1',
      );
      return const BudgetAlertPlanner().plan(
        entry: BudgetProgressEntry(
          budget: budget,
          spent: Money(110000, 'SAR'),
          remaining: Money(-10000, 'SAR'),
          ratio: 1.1,
          periodStart: DateTime.utc(2026, 8, 1),
          periodEnd: DateTime.utc(2026, 9, 1),
          health: BudgetHealth.over,
        ),
        now: DateTime.utc(2026, 8, 15),
        currencyLabel: 'ريال',
        categoryLabel: 'تسوق',
        accountLabel: account,
      );
    }

    test('it names the account the budget belongs to', () {
      final content = plan(account: 'الراجحي')!;
      expect(content.body, contains('تسوق في الراجحي'),
          reason: 'the QA case: a shopping warning arriving after an unrelated '
              'food purchase read as though the food belonged to shopping, '
              'because the alert named neither the budget nor its account');
    });

    test('it states the threshold that fired it', () {
      expect(plan(account: 'الراجحي')!.body, contains('١٠٠٪'));
    });

    test('with no account it still reads correctly, without inventing one', () {
      final content = plan()!;
      expect(content.body, contains('ميزانية تسوق'));
      expect(content.body.contains(' في null'), isFalse);
    });
  });

  group('R-8 — a capture notification cannot mis-scale a currency', () {
    test('a 3-decimal currency is not rounded to 2', () {
      expect(fmtCaptureMoney(Money(12345, 'KWD')), '12.345',
          reason: 'the old double formatter printed 12.35 — a different number');
    });

    test('the approved brevity rule survives', () {
      expect(fmtCaptureMoney(Money(15000, 'SAR')), '150');
      expect(fmtCaptureMoney(Money(15050, 'SAR')), '150.50');
    });

    test('a 0-decimal currency shows no phantom fraction', () {
      expect(fmtCaptureMoney(Money(150, 'JPY')), '150');
    });

    test('a category is shown only when it is actually resolved', () {
      // The finding's second half: "should show the resolved category when one
      // is actually known and should not fabricate it when confidence is
      // insufficient."
      expect(captureCategoryLabel('groceries'), isNotNull);
      expect(captureCategoryLabel(null), isNull);
      expect(captureCategoryLabel('not_a_real_key'), isNull);
    });
  });

  group('the information gaps are closed at the surfaces that render them', () {
    test('UX-004 — a plan names the accounts it counts', () {
      final src =
          File('lib/features/plans/plans_screen.dart').readAsStringSync();
      expect(src, contains('_planScopeLabel'));
      expect(src, contains('كل المصروفات في الفترة'),
          reason: 'MALI-048n: an empty selection means ALL expenses, and '
              'rendering it blank would hide the widest scope the app has');
      expect(src, contains('PlanScopeMode.allExpenses'));
    });

    test('UX-024 — Subscriptions names the account it is scoped to', () {
      final providers =
          File('lib/features/subscriptions/subscriptions_providers.dart')
              .readAsStringSync();
      expect(providers, contains('billsScopeAccountProvider'),
          reason: 'the label must come from the SAME resolution the filter '
              'used, or the two can drift apart');
      expect(providers, contains('await ref.watch(billsScopeAccountProvider.future)'));

      final screen = File('lib/features/subscriptions/subscriptions_screen.dart')
          .readAsStringSync();
      expect(screen, contains('scopeAccountName'));
      expect(screen, contains('billsScopeAccountProvider'));
    });

    test('UX-031 — the message centre dates its rows', () {
      final src = File('lib/features/announcements/announcements_screen.dart')
          .readAsStringSync();
      expect(src, contains('dateLabel(context)'));
      expect(src, contains("'من \$date'"),
          reason: 'a campaign/announcement `sortAt` is validFrom — when it '
              'STARTED being shown — not when it was delivered');
    });

    test('UX-015 — the card source is stated in customer language', () {
      final src = File('lib/features/accounts/account_detail_screen.dart')
          .readAsStringSync();
      expect(src.contains("? 'تلقائية' : 'يدوية'"), isFalse);
      expect(src, contains('اتعرفت من رسائل البنك'));
      expect(src, contains('أضفتها بنفسك'));
    });

    test('UX-026 — the ambiguous tab names its domain', () {
      final src =
          File('lib/features/budgets/budgets_screen.dart').readAsStringSync();
      expect(src, contains("'سجل الميزانيات'"));
      expect(src.contains("tabs: const ['الميزانيات', 'السجل', 'الأهداف']"),
          isFalse);
    });
  });

  group('UX-028 / UX-029 / UX-030 — Settings', () {
    final src =
        File('lib/features/settings/settings_screen.dart').readAsStringSync();

    test('«الحساب» is no longer two different sections', () {
      expect("'الحساب'".allMatches(src).length, 0,
          reason: 'two unrelated groups shared one heading; both are now named '
              'for what they contain');
      expect(src, contains("title: 'بيانات حسابك'"));
      expect(src, contains("title: 'الخروج وحذف البيانات'"));
    });

    test('the Reports duplicate route is gone from Settings', () {
      // UX-029's own instruction: "Fixing UX-012 should reduce this list, not
      // duplicate it." UX-012 is fixed — every bottom-nav tab now carries a
      // text label, «التحليلات» among them.
      expect(src.contains("title: 'الرؤى والتقارير'"), isFalse);
      final shell =
          File('lib/features/app/app_shell.dart').readAsStringSync();
      expect(shell, contains("label: 'التحليلات'"));
    });

    test('the ten-entry hub is split into destinations and configuration', () {
      expect(src.contains("title: 'إدارة أموالك'"), isFalse);
      expect(src, contains("title: 'حساباتك والتزاماتك'"));
      expect(src, contains("title: 'أدوات وإعدادات'"));
    });

    test('UX-030 — the encryption claim is made, and is TRUE', () {
      expect(src, contains('قاعدة بيانات مشفّرة'));
      // The claim must be verifiable, not marketing. Both halves are asserted
      // against the code that implements them.
      final db = File('lib/data/db/app_database.dart').readAsStringSync();
      expect(db, contains("PRAGMA cipher = 'sqlcipher';"));
      expect(db, contains('would not be encrypted'),
          reason: 'the open FAILS CLOSED rather than continuing unencrypted — '
              'without that, the claim would be conditional');
      expect(File('lib/data/db/database_key_store.dart').readAsStringSync(),
          contains('FlutterSecureStorage'),
          reason: 'the key is in the platform keychain, as the copy says');
    });

    test('the claim does NOT overreach into end-to-end encryption', () {
      // Local-database encryption is what the code does. Claiming end-to-end
      // would be a stronger promise than the product keeps, and a privacy claim
      // that overstates is worse than the silence it replaces.
      expect(src.contains('تشفير طرف لطرف'), isFalse);
      expect(src.contains('تشفير من طرف إلى طرف'), isFalse);
    });
  });

  group('UX-032 — the announcement banner keeps its own vertical rhythm', () {
    final src = File('lib/features/common/widgets/announcement_banner.dart')
        .readAsStringSync();

    test('the banner carries bottom spacing in BOTH layouts', () {
      // Two padding sites: the single-banner path and the horizontal-scroll
      // path. The QA required the rhythm to hold "at every announcement
      // length", and a multi-banner row is one of those lengths.
      expect('EdgeInsets.fromLTRB('.allMatches(src).length, 2,
          reason: 'single-banner and horizontal-scroll paths both need it');
      expect(src.contains('EdgeInsets.symmetric(horizontal: AppSpacing.gutter)'),
          isFalse,
          reason: 'horizontal-only padding is what left it flush against the '
              'smart-inbox card below');
    });

    test('the spacing lives inside the widget, not beside it on Home', () {
      // The widget collapses to SizedBox.shrink() when there is nothing to
      // show. A spacer on Home would leave a permanent gap on the far more
      // common no-announcement screen.
      expect(src, contains('SizedBox.shrink()'));
      final home =
          File('lib/features/dashboard/dashboard_screen.dart').readAsStringSync();
      expect(
        home,
        contains('const AnnouncementBanner(),\n              const _SetupNudgeCard(),'),
        reason: 'no compensating spacer was added at the call site',
      );
    });
  });

  group('UX-010 — a section with nothing in it says so, it does not vanish',
      () {
    final home =
        File('lib/features/dashboard/dashboard_screen.dart').readAsStringSync();

    test('none of the three account-scoped sections is conditionally omitted',
        () {
      // The original defect: switching accounts made whole sections disappear
      // with no header, which reads as breakage. Verified as the ABSENCE of the
      // conditional that removed them — a "4 empty-state hits" grep is what
      // made this look closed when it was not.
      expect(home.contains('if (data.budgetProgress.isNotEmpty) ...['), isFalse);
      expect(home.contains('if (data.activeGoal != null) ...['), isFalse);
      expect(home.contains('if (subs.isEmpty) return const SizedBox.shrink();'),
          isFalse);
    });

    test('each says which account has nothing, not just "empty"', () {
      // The QA paired this with UX-007: now that the chip names the active
      // account, «على الحساب ده» is a sentence the user can act on.
      expect(home, contains('مفيش ميزانيات على الحساب ده.'));
      expect(home, contains('مفيش أهداف على الحساب ده.'));
      expect(home, contains('مفيش اشتراكات على الحساب ده.'));
    });

    test('an account with NO data still gets the full-screen empty state', () {
      // Three empty section headers would be a worse answer than one clear one.
      expect(home, contains('if (data.isEmpty)\n                _empty(context)'));
    });

    test('the note is quiet, not a stack of full empty-state archetypes', () {
      expect(home, contains('class _SectionEmptyNote'));
      expect(home, contains('AppTypography.caption(c.textSecondary)'));
    });
  });

  group('UX-014 — a long account name is readable', () {
    test('the header title may wrap when the title is user data', () {
      final header =
          File('lib/features/common/app_header.dart').readAsStringSync();
      expect(header, contains('this.titleMaxLines = 1'),
          reason: 'opt-in: a fixed screen name does not need two lines');
      expect(header, contains('maxLines: titleMaxLines'));
    });

    test('the bar grows with the lines it permits', () {
      final header =
          File('lib/features/common/app_header.dart').readAsStringSync();
      expect(header, contains('(titleMaxLines - 1) * 28.0'),
          reason: 'allowing a wrap without room for it just clips lower');
    });

    test('the account detail screen opts in', () {
      final src = File('lib/features/accounts/account_detail_screen.dart')
          .readAsStringSync();
      expect(src, contains('titleMaxLines: 2'));
    });
  });

  group('UX-003 — the budget sheet is honest and actionable', () {
    final src =
        File('lib/features/budgets/budgets_screen.dart').readAsStringSync();

    test('the 20-row cap is disclosed rather than silent', () {
      expect(src, contains('_kPeriodTransactionLimit'));
      expect(src, contains('history.transactions.length > _kPeriodTransactionLimit'));
      expect(src, contains('باقي '),
          reason: 'F-009 class — a silent cap makes 60 transactions look like 20');
    });

    test('the count is stated even when nothing is truncated', () {
      expect(src, contains('history.transactions.isNotEmpty'));
    });

    test('the sheet offers an action, not just a read-only view', () {
      expect(src, contains('تعديل الميزانية'));
      expect(src, contains('budgetId: entry.budget.id'));
    });
  });

  group('UX-016 — pending transactions can be isolated FROM the list', () {
    final src = File('lib/features/transactions/transactions_screen.dart')
        .readAsStringSync();

    test('the screen offers a «قيد المراجعة» filter of its own', () {
      // The filter itself already existed. It was reachable from exactly two
      // places, both OUTSIDE this screen — the Home banner and a notification
      // tap — while Transactions showed «1 قيد المراجعة» in its header and told
      // the user to review those items.
      expect(src, contains('class _PendingFilterChip'));
      expect(src, contains('_PendingFilterChip(),'),
          reason: 'declared and MOUNTED — an unmounted control fixes nothing');
    });

    test('it is a toggle, not a fifth kind chip', () {
      // «مصروفات» + «قيد المراجعة» is a meaningful combination; a fifth kind
      // chip would have made them mutually exclusive, and the provider ANDs
      // pendingOnly with the kind filter rather than replacing it.
      expect(src, contains('.state =\n          !active'));
      final providers =
          File('lib/features/transactions/transactions_providers.dart')
              .readAsStringSync();
      expect(providers, contains('transactionsPendingFilterProvider'));
    });
  });

  group('UX-036 — a plan is labelled in ITS currency, not the base one', () {
    final src =
        File('lib/features/plans/plan_form_sheet.dart').readAsStringSync();

    test('the hardcoded «جنيه» is gone', () {
      expect(src.contains("'جنيه'"), isFalse);
    });

    test('editing an existing plan shows that plan currency', () {
      // The residual half: the suffix read the BASE currency while `_save`
      // writes `existing.currency`. Editing an EGP plan on a SAR base labelled
      // the field «ريال» while storing EGP.
      expect(src, contains('widget.existing?.currency ??'));
      expect(src, contains('Currency.arabicLabel(planCurrencyCode)'));
    });

    test('the save path and the label read the SAME source', () {
      final saveIdx = src.indexOf('Future<void> _save()');
      final saveBody = src.substring(saveIdx, saveIdx + 400);
      expect(saveBody, contains('widget.existing?.currency ??'));
    });

    test('the mixed-currency rule is stated, not left to be discovered', () {
      expect(src, contains('مش هيتحسب فيها'));
    });
  });

  group('NEW — «تجاهل الكل» was a bulk destructive action with no guard', () {
    final src = File('lib/features/transactions/transactions_screen.dart')
        .readAsStringSync();

    test('it now states how many it will dismiss', () {
      expect(src, contains(r"'تجاهل الكل (${dupes.length})'"));
      expect(src, contains(r"'تجاهل ${dupes.length} تنبيه؟'"));
    });

    test('it is confirmed before anything is deleted', () {
      final i = src.indexOf('تجاهل الكل');
      final body = src.substring(i - 200, i + 2200);
      expect(body, contains('if (proceed != true) return;'));
      expect(body.indexOf('showDialog<bool>'),
          lessThan(body.indexOf('repo.delete(d.id)')),
          reason: 'the confirmation must precede the deletion, not follow it');
    });

    test('it says what is and is NOT affected', () {
      expect(src, contains('العمليات نفسها '),
          reason: 'it discards duplicate FLAGS, not transactions — the '
              'difference is the whole reason the action is acceptable at all');
    });
  });

  group('UX-034 — the account and the card are separate facts', () {
    final src = File('lib/features/transactions/transaction_details_screen.dart')
        .readAsStringSync();

    test('they are separate labelled rows, not one «المصدر» string', () {
      expect(src.contains(r"${tx.cardLast4 != null ? ' · ${tx.cardLast4}' : ''}"),
          isFalse);
      expect(src, contains("'الحساب'"));
      expect(src, contains("'البطاقة'"));
    });

    test('«بدون بطاقة» exists as an explicit action', () {
      expect(src, contains('بدون بطاقة'));
    });

    test('the consequence is STATED, because the finding requires it', () {
      expect(src, contains('تغيير البطاقة لا ينقل العملية إلى حساب آخر'));
      expect(src, contains('العملية لسه في نفس الحساب'));
    });

    test('and the stated consequence is true of the repository', () {
      // The claim is only safe because `updateCard` writes card_last4 and
      // nothing else. If that ever changes, the copy becomes a lie.
      final repo =
          File('lib/data/repositories/drift_transaction_repository.dart')
              .readAsStringSync();
      final i = repo.indexOf('Future<void> updateCard');
      final body = repo.substring(i, i + 700);
      expect(body, contains('UPDATE transactions SET card_last4 = ?'));
      expect(body.contains('account_id ='), isFalse,
          reason: 'changing a card must not move the transaction to another '
              'account — the sheet promises exactly this');
    });

    test('only cards on the transaction OWN account are offered', () {
      expect(src, contains('card.accountId == tx.accountId'),
          reason: 'offering every card would invite a pairing that '
              'contradicts the account shown one row above');
    });

    test('a dismissed sheet is not read as «detach the card»', () {
      expect(src, contains("'__none__'"),
          reason: 'null is also what a dismissed sheet returns');
    });
  });
}
