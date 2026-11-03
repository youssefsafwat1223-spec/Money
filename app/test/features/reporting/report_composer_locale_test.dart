import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:money_companion/domain/entities/category_spend.dart';
import 'package:money_companion/domain/entities/report_models.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/reporting/date_range.dart';
import 'package:money_companion/domain/reporting/report_data_snapshot.dart';
import 'package:money_companion/domain/reporting/report_request.dart';
import 'package:money_companion/features/reporting/composition/report_composer.dart';

ReportDataSnapshot _snapshot(String language, {Money? amount, bool privacy = false}) {
  final day = DateTime(2026, 10, 17, 12);
  final total = amount ?? Money.parse('12.34', 'EGP');
  final transactions = [
    for (final category in ['groceries', 'custom']) TransactionEntity(
      id: 'tx-$category', amountMoney: total, currency: total.currency,
      type: TransactionTypeEntity.payment, source: TransactionSourceEntity.bank,
      occurredAt: day, rawMessage: 'Synthetic fixture', rawMerchant: 'متجر يوسف',
      categoryId: category, parseConfidence: 1,
      status: TransactionStatus.confirmed, createdAt: day, updatedAt: day,
    ),
  ];
  final breakdown = amount != null ? [
    CategorySpend(categoryId: 'groceries', total: total),
  ] : [
    CategorySpend(categoryId: 'groceries', total: Money.parse('10', 'EGP')),
    CategorySpend(categoryId: 'custom', total: Money.parse('2.34', 'EGP')),
  ];
  return ReportDataSnapshot(
    capturedAt: day,
    request: ReportRequest(period: const MonthlyPeriod(), languageCode: language,
      scope: const SingleAccountScope('account'), privacyMode: privacy,
      content: const ReportContentOptions(includeTransactionDetails: true)),
    range: DateRange(DateTime(2026, 10), DateTime(2026, 11)),
    previousRange: DateRange(DateTime(2026, 9), DateTime(2026, 10)),
    accountsInScope: [ReportAccountRef(id: 'account', name: 'حساب يوسف',
      currency: total.currency, excludeFromTotals: false)],
    currencyTotals: [CurrencyTotal(currency: total.currency, income: Money.zero(total.currency),
      expense: total)],
    previousCurrencyTotals: const [], totalIncome: Money.zero(total.currency),
    totalExpense: total, categoryBreakdown: breakdown,
    categoryBreakdownByCurrency: {total.currency: breakdown},
    categoryMeta: const {
      'groceries': ReportCategoryMeta(id: 'groceries', key: 'groceries',
        name: 'بقالة', colorHex: '#16A37F'),
      'custom': ReportCategoryMeta(id: 'custom', key: 'custom_7348',
        name: 'مصروفات يوسف', colorHex: '#16A37F'),
    },
    dailyExpense: [DailySpend(day: day, total: total)], topMerchants: const [],
    largestTransactions: transactions, appendixTransactions: transactions,
    latestBalance: null,
  );
}

void main() {
  for (final language in ['en', 'ar']) {
    test('largest rows follow $language request despite opposite global locale', () {
      final oldLocale = Intl.defaultLocale;
      addTearDown(() => Intl.defaultLocale = oldLocale);
      Intl.defaultLocale = language == 'en' ? 'ar' : 'en';
      final model = const ReportComposer().compose(_snapshot(language));
      final date = language == 'en' ? '17 October 2026' : '17 أكتوبر 2026';
      expect(model.largest.first.subtitle,
          '${language == 'en' ? 'Groceries' : 'بقالة'} · $date');
      expect(model.largest.last.subtitle, 'مصروفات يوسف · $date',
          reason: 'a custom category has no translated catalog name');
      expect(model.largest.map((row) => row.title), ['متجر يوسف', 'متجر يوسف']);
      expect(model.cover.scopeLabel, 'حساب يوسف');
      expect(model.largest.first.value,
          language == 'en' ? '−12.34 EGP' : '−12.34 جنيه');
      expect(model.category.rows.map((row) => row.label),
          [language == 'en' ? 'Groceries' : 'بقالة', 'مصروفات يوسف']);
      expect(model.category.rows.map((row) => row.value), language == 'en'
          ? ['10.00 EGP', '2.34 EGP'] : ['10.00 جنيه', '2.34 جنيه']);
      expect(model.appendix.map((row) => row.category),
          [language == 'en' ? 'Groceries' : 'بقالة', 'مصروفات يوسف']);
      expect(model.appendix.map((row) => row.merchant),
          ['متجر يوسف', 'متجر يوسف']);
      expect(model.appendix.map((row) => row.date), [date, date]);
    });

    test('all exact report leaves retain KWD minor units above2^53 in $language', () {
      final model = const ReportComposer().compose(_snapshot(language,
          amount: Money(9007199254740993, 'KWD')));
      final token = language == 'en' ? 'KWD' : 'دينار';
      final amount = '9,007,199,254,740.993 $token';
      expect(model.summary.tiles[1].value, amount);
      expect(model.cashFlow.single.expense, amount);
      expect(model.category.rows.single.value, amount);
      expect(model.largest.first.value, '−$amount');
      expect(model.appendix.first.amount, '−$amount');
    });

    test('privacy masks exact report leaves in $language', () {
      final model = const ReportComposer().compose(_snapshot(language,
          amount: Money(9007199254740993, 'KWD'), privacy: true));
      expect(model.summary.tiles[1].value, '••••');
      expect(model.largest.first.value, '••••');
      expect(model.appendix.first.amount, '••••');
    });
  }
}
