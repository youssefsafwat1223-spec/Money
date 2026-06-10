import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/app_database.dart';
import '../../data/repositories/drift_budget_repository.dart';
import '../../data/repositories/drift_category_repository.dart';
import '../../data/repositories/drift_gamification_repository.dart';
import '../../data/repositories/drift_goal_repository.dart';
import '../../data/repositories/drift_merchant_category_repository.dart';
import '../../data/repositories/drift_transaction_repository.dart';
import '../../data/repositories/drift_user_settings_repository.dart';
import '../../domain/repositories/budget_repository.dart';
import '../../domain/repositories/category_repository.dart';
import '../../domain/repositories/gamification_repository.dart';
import '../../domain/repositories/goal_repository.dart';
import '../../domain/repositories/merchant_category_repository.dart';
import '../../domain/repositories/transaction_repository.dart';
import '../../domain/repositories/user_settings_repository.dart';
import '../../domain/usecases/add_transaction_usecase.dart';
import '../../domain/usecases/budget_progress_usecase.dart';
import '../../domain/usecases/confirm_transaction_usecase.dart';
import '../../domain/usecases/correct_category_usecase.dart';
import '../../domain/usecases/engagement_usecase.dart';
import '../../domain/usecases/goal_details_usecase.dart';
import '../../domain/usecases/ingest_captured_message_usecase.dart';
import '../../domain/usecases/save_budget_usecase.dart';
import '../../domain/usecases/save_goal_usecase.dart';
import '../../domain/usecases/user_settings_usecases.dart';
import '../../features/app/celebration_runtime.dart';

final appDatabaseProvider = Provider<AppDatabase>((ref) {
  throw UnimplementedError('AppDatabase must be provided from main().');
});

final transactionRepositoryProvider = Provider<TransactionRepository>((ref) {
  return DriftTransactionRepository(ref.watch(appDatabaseProvider));
});

final merchantCategoryRepositoryProvider =
    Provider<MerchantCategoryRepository>((ref) {
  return DriftMerchantCategoryRepository(ref.watch(appDatabaseProvider));
});

final budgetRepositoryProvider = Provider<BudgetRepository>((ref) {
  return DriftBudgetRepository(ref.watch(appDatabaseProvider));
});

final goalRepositoryProvider = Provider<GoalRepository>((ref) {
  return DriftGoalRepository(ref.watch(appDatabaseProvider));
});

final gamificationRepositoryProvider = Provider<GamificationRepository>((ref) {
  return DriftGamificationRepository(ref.watch(appDatabaseProvider));
});

final userSettingsRepositoryProvider = Provider<UserSettingsRepository>((ref) {
  return DriftUserSettingsRepository(ref.watch(appDatabaseProvider));
});

final categoryRepositoryProvider = Provider<CategoryRepository>((ref) {
  return DriftCategoryRepository(ref.watch(appDatabaseProvider));
});

final recordEngagementUseCaseProvider = Provider<RecordEngagementUseCase>((ref) {
  return RecordEngagementUseCase(
    gamificationRepository: ref.watch(gamificationRepositoryProvider),
    transactionRepository: ref.watch(transactionRepositoryProvider),
    userSettingsRepository: ref.watch(userSettingsRepositoryProvider),
    onUpdate: (update) =>
        CelebrationRuntime.instance.pushAll(update.celebrations),
  );
});

final addTransactionUseCaseProvider = Provider<AddTransactionUseCase>((ref) {
  return AddTransactionUseCase(
    transactionRepository: ref.watch(transactionRepositoryProvider),
    merchantCategoryRepository: ref.watch(merchantCategoryRepositoryProvider),
    recordEngagementUseCase: ref.watch(recordEngagementUseCaseProvider),
  );
});

final ingestCapturedMessageUseCaseProvider =
    Provider<IngestCapturedMessageUseCase>((ref) {
      return IngestCapturedMessageUseCase(
        ref.watch(addTransactionUseCaseProvider),
      );
    });

final confirmTransactionUseCaseProvider =
    Provider<ConfirmTransactionUseCase>((ref) {
  return ConfirmTransactionUseCase(
    ref.watch(transactionRepositoryProvider),
    recordEngagementUseCase: ref.watch(recordEngagementUseCaseProvider),
  );
});

final correctCategoryUseCaseProvider = Provider<CorrectCategoryUseCase>((ref) {
  return CorrectCategoryUseCase(
    transactionRepository: ref.watch(transactionRepositoryProvider),
    merchantCategoryRepository: ref.watch(merchantCategoryRepositoryProvider),
    recordEngagementUseCase: ref.watch(recordEngagementUseCaseProvider),
  );
});

final saveBudgetUseCaseProvider = Provider<SaveBudgetUseCase>((ref) {
  return SaveBudgetUseCase(
    ref.watch(budgetRepositoryProvider),
    recordEngagementUseCase: ref.watch(recordEngagementUseCaseProvider),
  );
});

final deleteBudgetUseCaseProvider = Provider<DeleteBudgetUseCase>((ref) {
  return DeleteBudgetUseCase(ref.watch(budgetRepositoryProvider));
});

final saveGoalUseCaseProvider = Provider<SaveGoalUseCase>((ref) {
  return SaveGoalUseCase(
    ref.watch(goalRepositoryProvider),
    recordEngagementUseCase: ref.watch(recordEngagementUseCaseProvider),
  );
});

final deleteGoalUseCaseProvider = Provider<DeleteGoalUseCase>((ref) {
  return DeleteGoalUseCase(ref.watch(goalRepositoryProvider));
});

final addGoalContributionUseCaseProvider =
    Provider<AddGoalContributionUseCase>((ref) {
  return AddGoalContributionUseCase(
    ref.watch(goalRepositoryProvider),
    recordEngagementUseCase: ref.watch(recordEngagementUseCaseProvider),
  );
    });

final budgetProgressUseCaseProvider = Provider<BudgetProgressUseCase>((ref) {
  return BudgetProgressUseCase(
    budgetRepository: ref.watch(budgetRepositoryProvider),
    transactionRepository: ref.watch(transactionRepositoryProvider),
    recordEngagementUseCase: ref.watch(recordEngagementUseCaseProvider),
  );
});

final goalDetailsUseCaseProvider = Provider<GoalDetailsUseCase>((ref) {
  return GoalDetailsUseCase(ref.watch(goalRepositoryProvider));
});

final loadNotificationPreferencesUseCaseProvider =
    Provider<LoadNotificationPreferencesUseCase>((ref) {
  return LoadNotificationPreferencesUseCase(
    ref.watch(userSettingsRepositoryProvider),
  );
});

final saveNotificationPreferencesUseCaseProvider =
    Provider<SaveNotificationPreferencesUseCase>((ref) {
  return SaveNotificationPreferencesUseCase(
    ref.watch(userSettingsRepositoryProvider),
  );
});

final loadUserSettingsUseCaseProvider = Provider<LoadUserSettingsUseCase>((ref) {
  return LoadUserSettingsUseCase(ref.watch(userSettingsRepositoryProvider));
});

final saveThemeModeUseCaseProvider = Provider<SaveThemeModeUseCase>((ref) {
  return SaveThemeModeUseCase(ref.watch(userSettingsRepositoryProvider));
});
