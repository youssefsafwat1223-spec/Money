import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../domain/entities/budget_entity.dart';
import '../../domain/entities/engagement_entities.dart';
import '../common/category_catalog.dart';

class BudgetsView {
  const BudgetsView({
    required this.snapshot,
    required this.catalog,
  });

  final BudgetProgressSnapshot snapshot;
  final CategoryCatalog catalog;
}

final budgetsViewProvider = FutureProvider<BudgetsView>((ref) async {
  final snapshot = await ref.watch(budgetProgressUseCaseProvider).call();
  final catalog = await ref.watch(categoryCatalogProvider.future);
  return BudgetsView(snapshot: snapshot, catalog: catalog);
});

final budgetByIdProvider =
    FutureProvider.family<BudgetEntity?, String>((ref, id) async {
  ref.watch(budgetsViewProvider);
  return ref.watch(budgetRepositoryProvider).getById(id);
});

void refreshBudgets(WidgetRef ref) {
  ref.invalidate(budgetsViewProvider);
}
