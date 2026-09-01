import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import 'savings_repository.dart';

/// COUPONS Phase 4 — the savings read path.
///
/// Local only. There is no provider here that uploads, and no server endpoint
/// that would accept it: a server-side savings total would be a spending
/// profile, and the user is the only party who needs to know what they saved.

final savingsRepositoryProvider = Provider<SavingsRepository>((ref) {
  return SavingsRepository(ref.watch(appDatabaseProvider));
});

/// Totals split by currency AND by evidence.
///
/// Deliberately not a single number — see [SavingsTotals]. The screen renders
/// the breakdown, and there is no provider that flattens it, so a future caller
/// cannot accidentally present one unqualified figure.
final savingsTotalsProvider = FutureProvider<SavingsTotals>((ref) async {
  ref.watch(dbRevisionProvider);
  return ref.watch(savingsRepositoryProvider).totals();
});

final savingsHistoryProvider = FutureProvider<List<SavingsEntry>>((ref) async {
  ref.watch(dbRevisionProvider);
  return ref.watch(savingsRepositoryProvider).history();
});
