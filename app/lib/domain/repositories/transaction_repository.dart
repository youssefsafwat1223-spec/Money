import '../entities/category_spend.dart';
import '../entities/report_models.dart';
import '../entities/transaction_entity.dart';

abstract class TransactionRepository {
  Future<TransactionEntity?> findDuplicate({
    required double amount,
    required String rawMerchant,
    required DateTime occurredAt,
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

  // ── قراءة (Sprint 3) ──

  /// أحدث العمليات (تتجاهل المُلغاة) — للـ Dashboard.
  Future<List<TransactionEntity>> getRecent({int limit = 5});

  /// كل العمليات (تتجاهل المُلغاة) مرتّبة بالأحدث — لشاشة العمليات.
  Future<List<TransactionEntity>> getAll();

  /// إجمالي المصروفات (payment + withdrawal) خلال فترة — لحساب «وفّرت».
  Future<double> expenseTotalBetween({
    required DateTime from,
    required DateTime to,
  });

  /// إجمالي الدخل خلال فترة — يعرض في Dashboard ولا يستهلك الميزانيات.
  Future<double> incomeTotalBetween({
    required DateTime from,
    required DateTime to,
  });

  /// آخر رصيد معروف من رسائل البنك، إن وُجد.
  Future<double?> latestBalanceAfter();

  /// صرف يومي خلال فترة — يستخدم للرسم البياني في Insights.
  Future<List<DailySpend>> dailyExpenseTotals({
    required DateTime from,
    required DateTime to,
  });

  /// تفصيل الإنفاق لكل تصنيف خلال فترة — لـ «أين ذهبت أموالك».
  Future<List<CategorySpend>> categoryBreakdown({
    required DateTime from,
    required DateTime to,
  });

  Future<double> categoryExpenseTotalBetween({
    required String categoryId,
    required DateTime from,
    required DateTime to,
  });

  /// أكثر المتاجر صرفاً خلال فترة — للتقارير.
  Future<List<MerchantSpend>> merchantBreakdown({
    required DateTime from,
    required DateTime to,
    int limit = 3,
  });

  /// اشتراكات متكررة مُكتشَفة (نفس المتجر بمبلغ متقارب عبر ≥2 أشهر).
  Future<List<RecurringCandidate>> recurringCandidates();
}
