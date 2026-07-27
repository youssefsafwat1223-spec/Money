import '../entities/card_summary.dart';
import '../entities/category_spend.dart';
import '../entities/report_models.dart';
import '../entities/transaction_entity.dart';
import '../services/card_account_grouper.dart';

abstract class TransactionRepository {
  Future<TransactionEntity?> findDuplicate({
    required double amount,
    required String rawMerchant,
    required DateTime occurredAt,
  });

  Future<TransactionEntity?> findSuspiciousDuplicate({
    required double amount,
    required String currency,
    required String merchantOrDescription,
    String? cardLast4,
    required DateTime comparisonTimestamp,
  });

  Future<TransactionEntity> saveTransaction({
    required TransactionEntity transaction,
    required String? categoryKey,
  });

  Future<TransactionEntity?> getById(String id);

  Future<TransactionEntity> confirm(String id);

  Future<TransactionEntity> updateCategory({
    required String transactionId,
    required String categoryKey,
  });

  Future<TransactionEntity> updateTransaction({
    required String transactionId,
    required double amount,
    required String currency,
    required TransactionTypeEntity type,
    required DateTime occurredAt,
    required String? rawMerchant,
    required String? categoryId,
    required String? note,
    String? accountId,
  });

  Future<void> deleteTransaction(String id);

  /// يعيد ربط العملية بحساب آخر (بدون تغيير باقي الحقول).
  Future<void> updateAccount({
    required String transactionId,
    required String accountId,
  });

  /// يربط العملية ببطاقة (آخر 4 أرقام)، أو يفصلها عند null.
  Future<void> updateCard({
    required String transactionId,
    required String? cardLast4,
  });

  /// يحدّث مبلغ العملية بعملة الحساب — يُستخدم لتسعير عملية أجنبية «بانتظار
  /// التسعير» (amount = 0) بقيمتها المحلية التي يدخلها المستخدم.
  Future<void> updateAmount({
    required String transactionId,
    required double amount,
  });

  // ── قراءة (Sprint 3) ──

  /// أحدث العمليات (تتجاهل المُلغاة) — للـ Dashboard.
  /// [accountId] لتصفية حساب محدد (null = كل الحسابات).
  Future<List<TransactionEntity>> getRecent({int limit = 5, String? accountId});

  /// كل العمليات (تتجاهل المُلغاة) مرتّبة بالأحدث — لشاشة العمليات.
  Future<List<TransactionEntity>> getAll();

  /// صفحة واحدة من العمليات مرتبة بالأحدث. [offset] صفري و[limit] حد أعلى.
  Future<List<TransactionEntity>> getPage(
      {required int offset, int limit = 500});

  /// إجمالي المصروفات (payment + withdrawal) خلال فترة — لحساب «وفّرت».
  Future<double> expenseTotalBetween({
    required DateTime from,
    required DateTime to,
    String? accountId,
  });

  /// إجمالي الدخل خلال فترة — يعرض في Dashboard ولا يستهلك الميزانيات.
  Future<double> incomeTotalBetween({
    required DateTime from,
    required DateTime to,
    String? accountId,
  });

  /// آخر رصيد معروف من رسائل البنك، إن وُجد.
  Future<double?> latestBalanceAfter({String? accountId});

  /// إجمالي المصروف والدخل مجمّعاً حسب العملة خلال فترة — لعرض «كل الحسابات».
  Future<List<CurrencyTotal>> currencyTotalsBetween({
    required DateTime from,
    required DateTime to,
  });

  /// صرف يومي خلال فترة — يستخدم للرسم البياني في Insights.
  Future<List<DailySpend>> dailyExpenseTotals({
    required DateTime from,
    required DateTime to,
    String? accountId,
  });

  /// تفصيل الإنفاق لكل تصنيف خلال فترة — لـ «أين ذهبت أموالك».
  Future<List<CategorySpend>> categoryBreakdown({
    required DateTime from,
    required DateTime to,
    String? accountId,
  });

  Future<double> categoryExpenseTotalBetween({
    required String categoryId,
    required DateTime from,
    required DateTime to,
    String? accountId,
  });

  /// أكثر المتاجر صرفاً خلال فترة — للتقارير.
  Future<List<MerchantSpend>> merchantBreakdown({
    required DateTime from,
    required DateTime to,
    int limit = 3,
    String? accountId,
  });

  /// اشتراكات متكررة مُكتشَفة (نفس المتجر بمبلغ متقارب عبر ≥2 أشهر).
  Future<List<RecurringCandidate>> recurringCandidates({String? accountId});

  /// ملخّص لكل بطاقة (آخر 4 أرقام + الشبكة + الداخل/الخارج).
  Future<List<CardSummary>> getCardSummaries();

  /// صفوف تجميعية لكل (آخر 4 أرقام، حساب) — أساس ربط البطاقة بحسابها بثقة.
  /// قراءة فقط؛ لا يكتب account_id.
  Future<List<CardAccountBreakdownRow>> getCardAccountBreakdown();

  /// عمليات بطاقة محددة (بآخر 4 أرقام) مرتّبة بالأحدث.
  Future<List<TransactionEntity>> getByCard(String last4);
}
