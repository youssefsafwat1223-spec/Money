import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../domain/entities/report_models.dart';

final subscriptionsProvider =
    FutureProvider<List<RecurringCandidate>>((ref) async {
  return ref.watch(transactionRepositoryProvider).recurringCandidates();
});
