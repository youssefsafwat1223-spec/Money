import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../domain/entities/account_entity.dart';
import '../../domain/entities/budget_entity.dart';
import '../../domain/entities/engagement_entities.dart';
import '../../domain/entities/goal_entity.dart';
import '../common/category_catalog.dart';

class BudgetsView {
  const BudgetsView({
    required this.snapshot,
    required this.catalog,
    required this.goals,
    required this.accounts,
  });

  final BudgetProgressSnapshot snapshot;
  final CategoryCatalog catalog;
  final List<GoalEntity> goals;
  final List<AccountEntity> accounts;

  String accountName(String? id) {
    if (id == null) return '';
    final match = accounts.where((a) => a.id == id);
    return match.isEmpty ? '' : match.first.name;
  }
}

final budgetsViewProvider = FutureProvider<BudgetsView>((ref) async {
  final snapshot = await ref.watch(budgetProgressUseCaseProvider).call();
  final catalog = await ref.watch(categoryCatalogProvider.future);
  final goals = (await ref.watch(goalRepositoryProvider).getAll())
      .where((goal) => goal.status == 'active')
      .toList(growable: false);
  final accounts = await ref.watch(accountRepositoryProvider).getAll();
  return BudgetsView(snapshot: snapshot, catalog: catalog, goals: goals, accounts: accounts);
});

final budgetsPageTabProvider = StateProvider<int>((ref) => 0);

final budgetByIdProvider =
    FutureProvider.family<BudgetEntity?, String>((ref, id) async {
  ref.watch(budgetsViewProvider);
  return ref.watch(budgetRepositoryProvider).getById(id);
});

void refreshBudgets(WidgetRef ref) {
  ref.invalidate(budgetsViewProvider);
}
