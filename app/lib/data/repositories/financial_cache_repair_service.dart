import '../db/app_database.dart';
import '../db/financial_cache_health.dart';
import 'supabase_account_repository.dart';
import 'supabase_bill_repository.dart';
import 'supabase_budget_repository.dart';
import 'supabase_goal_repository.dart';
import 'supabase_plan_repository.dart';
import 'supabase_smart_inbox_repository.dart';
import 'supabase_transaction_repository.dart';

/// يُشغَّل عند اكتشاف financial_cache_dirty=true (بعد فشل مرآة كتابة) —
/// يعيد بناء كاش Drift بالكامل من صفوف Supabase الموثوقة قبل السماح بأي
/// تراجع (rollback) آمن لعلامتي accounts_supabase_primary/
/// transactions_supabase_primary. لا يستدعي AccountsPullService أو
/// LedgerSyncService أو أي محرك مزامنة قديم.
class FinancialCacheRepairService {
  const FinancialCacheRepairService({
    required this.db,
    required this.accountsRepo,
    required this.transactionsRepo,
    required this.budgetsRepo,
    required this.goalsRepo,
    required this.billsRepo,
    required this.plansRepo,
    required this.smartInboxRepo,
  });

  final AppDatabase db;
  final SupabaseAccountRepository accountsRepo;
  final SupabaseTransactionRepository transactionsRepo;
  final SupabaseBudgetRepository budgetsRepo;
  final SupabaseGoalRepository goalsRepo;
  final SupabaseBillRepository billsRepo;
  final SupabasePlanRepository plansRepo;
  final SupabaseSmartInboxRepository smartInboxRepo;

  Future<void> repairAll() async {
    await accountsRepo.repairLocalCache();
    await transactionsRepo.repairLocalCache();
    await budgetsRepo.repairLocalCache();
    await goalsRepo.repairLocalCache();
    await billsRepo.repairLocalCache();
    await plansRepo.repairLocalCache();
    await smartInboxRepo.repairLocalCache();
  }

  Future<void> repairDirty() async {
    if (await isFinancialCacheDirty(db, accountsCacheEntityType)) {
      await accountsRepo.repairLocalCache();
    }
    if (await isFinancialCacheDirty(db, transactionsCacheEntityType)) {
      await transactionsRepo.repairLocalCache();
    }
    if (await isFinancialCacheDirty(db, budgetsCacheEntityType)) {
      await budgetsRepo.repairLocalCache();
    }
    if (await isFinancialCacheDirty(db, goalsCacheEntityType)) {
      await goalsRepo.repairLocalCache();
    }
    if (await isFinancialCacheDirty(db, subscriptionsCacheEntityType)) {
      await billsRepo.repairLocalCache();
    }
    if (await isFinancialCacheDirty(db, plansCacheEntityType)) {
      await plansRepo.repairLocalCache();
    }
    if (await isFinancialCacheDirty(db, smartInboxCacheEntityType)) {
      await smartInboxRepo.repairLocalCache();
    }
  }
}
