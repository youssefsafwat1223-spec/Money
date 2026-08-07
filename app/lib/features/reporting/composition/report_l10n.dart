/// Localised label set for a generated report.
///
/// Kept self-contained (not in the app's ARB/`AppL10n`) so the composer stays a
/// pure, `BuildContext`-free unit that can run before the render isolate. These
/// move into ARB when the UI flow (Phase 3) wires providers.
class ReportStrings {
  const ReportStrings({
    required this.reportTitle,
    required this.executiveSummary,
    required this.cashFlow,
    required this.income,
    required this.expense,
    required this.net,
    required this.savingsRate,
    required this.transactions,
    required this.transaction,
    required this.avgPerDay,
    required this.comparison,
    required this.metric,
    required this.thisPeriod,
    required this.previous,
    required this.change,
    required this.spendingByCategory,
    required this.totalSpend,
    required this.other,
    required this.dailyTrend,
    required this.avg,
    required this.largest,
    required this.allAccounts,
    required this.currencyWord,
    required this.languageName,
    required this.generatedLabel,
    required this.generatedOnDevice,
    required this.page,
    required this.ofWord,
    required this.sample,
    required this.verdictLess,
    required this.verdictMore,
    required this.verdictFlat,
    required this.budgetsTitle,
    required this.billsTitle,
    required this.goalsTitle,
    required this.observationsTitle,
    required this.appendixTitle,
    required this.appendixOmittedNotice,
    required this.appendixMore,
    required this.apxDate,
    required this.apxMerchant,
    required this.apxCategory,
    required this.apxAmount,
    required this.ofLimit,
    required this.over,
    required this.toGo,
    required this.subscription,
    required this.oneOff,
    required this.noData,
    required this.insightSpendingDecreased,
    required this.insightSpendingIncreased,
    required this.insightSavingsImproved,
    required this.insightSavingsDeclined,
    required this.insightBudgetsOver,
    required this.insightDominantCategory,
    required this.insightBillDueSoon,
    required this.insightUnusualDay,
    required this.months,
  });

  final String reportTitle;
  final String executiveSummary;
  final String cashFlow;
  final String income;
  final String expense;
  final String net;
  final String savingsRate;
  final String transactions;
  final String transaction;
  final String avgPerDay;
  final String comparison;
  final String metric;
  final String thisPeriod;
  final String previous;
  final String change;
  final String spendingByCategory;
  final String totalSpend;
  final String other;
  final String dailyTrend;
  final String avg;
  final String largest;
  final String allAccounts;
  final String currencyWord;
  final String languageName;
  final String generatedLabel;
  final String generatedOnDevice;
  final String page;
  final String ofWord;
  final String sample;

  /// Verdict templates; `{p}` is replaced with a formatted percentage.
  final String verdictLess;
  final String verdictMore;
  final String verdictFlat;

  final String budgetsTitle;
  final String billsTitle;
  final String goalsTitle;
  final String observationsTitle;
  final String appendixTitle;

  /// MALI-030 — shown IN the rendered report when the detailed appendix was omitted
  /// because the period exceeds the supported row bound (summaries stay complete).
  final String appendixOmittedNotice;
  final String appendixMore; // "+ {n} more transactions"
  final String apxDate;
  final String apxMerchant;
  final String apxCategory;
  final String apxAmount;
  final String ofLimit;
  final String over;
  final String toGo;
  final String subscription;
  final String oneOff;
  final String noData;

  // Insight templates ({pct}/{pp}/{count}/{category}/{share}/{bill}/{amount}/{days}/{factor}).
  final String insightSpendingDecreased;
  final String insightSpendingIncreased;
  final String insightSavingsImproved;
  final String insightSavingsDeclined;
  final String insightBudgetsOver;
  final String insightDominantCategory;
  final String insightBillDueSoon;
  final String insightUnusualDay;

  /// Full month names, index 0 = January.
  final List<String> months;

  static ReportStrings of(String languageCode) =>
      languageCode == 'ar' ? _ar : _en;

  static const ReportStrings _en = ReportStrings(
    reportTitle: 'Financial Report',
    executiveSummary: 'Executive summary',
    cashFlow: 'Cash flow',
    income: 'Income',
    expense: 'Expenses',
    net: 'Net cash flow',
    savingsRate: 'Savings rate',
    transactions: 'Transactions',
    transaction: 'Transaction',
    avgPerDay: 'Avg / day',
    comparison: 'Compared with previous period',
    metric: 'Metric',
    thisPeriod: 'This period',
    previous: 'Previous',
    change: 'Change',
    spendingByCategory: 'Spending by category',
    totalSpend: 'Total spend',
    other: 'Other',
    dailyTrend: 'Daily spending trend',
    avg: 'avg',
    largest: 'Largest transactions',
    allAccounts: 'All accounts',
    currencyWord: 'Currency',
    languageName: 'English',
    generatedLabel: 'Generated',
    generatedOnDevice:
        'Generated locally on your device — no financial data left the phone to create this report.',
    page: 'Page',
    ofWord: 'of',
    sample: 'SAMPLE',
    verdictLess: 'You spent {p} less than the previous period.',
    verdictMore: 'You spent {p} more than the previous period.',
    verdictFlat: 'Your spending was in line with the previous period.',
    budgetsTitle: 'Budget performance',
    billsTitle: 'Bills & subscriptions',
    goalsTitle: 'Goal progress',
    observationsTitle: 'Observations',
    appendixTitle: 'Transaction appendix',
    appendixOmittedNotice:
        'The detailed transaction appendix was omitted because the selected '
        'period exceeds the supported 5,000-row appendix limit. Report summaries '
        'and totals still cover the full selected period.',
    appendixMore: '+ {n} more transactions',
    apxDate: 'Date',
    apxMerchant: 'Merchant',
    apxCategory: 'Category',
    apxAmount: 'Amount',
    ofLimit: 'of limit',
    over: 'over',
    toGo: 'to go',
    subscription: 'Subscription',
    oneOff: 'Bill',
    noData: 'No data for this section.',
    insightSpendingDecreased: 'You spent {pct} less than the previous period.',
    insightSpendingIncreased: 'You spent {pct} more than the previous period.',
    insightSavingsImproved: 'Your savings rate improved by {pp}.',
    insightSavingsDeclined: 'Your savings rate declined by {pp}.',
    insightBudgetsOver: '{count} budget(s) went over their limit.',
    insightDominantCategory:
        '{category} was your largest category at {share} of spending.',
    insightBillDueSoon: '{bill} ({amount}) is due in {days} days.',
    insightUnusualDay:
        'An unusual spend of {amount} — {factor}× your daily average.',
    months: <String>[
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December',
    ],
  );

  static const ReportStrings _ar = ReportStrings(
    reportTitle: 'التقرير المالي',
    executiveSummary: 'الملخص التنفيذي',
    cashFlow: 'التدفق النقدي',
    income: 'الدخل',
    expense: 'المصروفات',
    net: 'صافي التدفق',
    savingsRate: 'معدل الادخار',
    transactions: 'عدد العمليات',
    transaction: 'عملية',
    avgPerDay: 'المتوسط اليومي',
    comparison: 'مقارنة بالفترة السابقة',
    metric: 'المؤشر',
    thisPeriod: 'هذه الفترة',
    previous: 'السابقة',
    change: 'التغيّر',
    spendingByCategory: 'الإنفاق حسب الفئة',
    totalSpend: 'إجمالي الإنفاق',
    other: 'أخرى',
    dailyTrend: 'اتجاه الإنفاق اليومي',
    avg: 'المتوسط',
    largest: 'أكبر العمليات',
    allAccounts: 'جميع الحسابات',
    currencyWord: 'العملة',
    languageName: 'العربية',
    generatedLabel: 'تاريخ الإنشاء',
    generatedOnDevice:
        'أُنشئ محليًا على جهازك — لم تغادر أي بيانات مالية الهاتف لإنشاء هذا التقرير.',
    page: 'صفحة',
    ofWord: 'من',
    sample: 'عيّنة',
    verdictLess: 'أنفقت {p} أقل من الفترة السابقة.',
    verdictMore: 'أنفقت {p} أكثر من الفترة السابقة.',
    verdictFlat: 'كان إنفاقك مقاربًا للفترة السابقة.',
    budgetsTitle: 'أداء الميزانيات',
    billsTitle: 'الفواتير والاشتراكات',
    goalsTitle: 'تقدّم الأهداف',
    observationsTitle: 'ملاحظات',
    appendixTitle: 'ملحق العمليات',
    appendixOmittedNotice:
        'تم حذف الملحق التفصيلي لأن عدد العمليات تجاوز الحد المدعوم (5000 عملية). '
        'جميع الملخصات والإجماليات في التقرير ما زالت تشمل الفترة كاملة.',
    appendixMore: '+ {n} عملية أخرى',
    apxDate: 'التاريخ',
    apxMerchant: 'التاجر',
    apxCategory: 'الفئة',
    apxAmount: 'المبلغ',
    ofLimit: 'من الحد',
    over: 'تجاوز',
    toGo: 'متبقٍ',
    subscription: 'اشتراك',
    oneOff: 'فاتورة',
    noData: 'لا توجد بيانات لهذا القسم.',
    insightSpendingDecreased: 'أنفقت {pct} أقل من الفترة السابقة.',
    insightSpendingIncreased: 'أنفقت {pct} أكثر من الفترة السابقة.',
    insightSavingsImproved: 'تحسّن معدل ادخارك بمقدار {pp}.',
    insightSavingsDeclined: 'انخفض معدل ادخارك بمقدار {pp}.',
    insightBudgetsOver: 'تجاوزت {count} ميزانية حدّها.',
    insightDominantCategory: 'كانت {category} أكبر فئة إنفاق بنسبة {share}.',
    insightBillDueSoon: '{bill} ({amount}) مستحقة خلال {days} يوم.',
    insightUnusualDay: 'إنفاق غير معتاد بمبلغ {amount} — {factor} ضعف متوسطك اليومي.',
    months: <String>[
      'يناير', 'فبراير', 'مارس', 'أبريل', 'مايو', 'يونيو',
      'يوليو', 'أغسطس', 'سبتمبر', 'أكتوبر', 'نوفمبر', 'ديسمبر',
    ],
  );
}
