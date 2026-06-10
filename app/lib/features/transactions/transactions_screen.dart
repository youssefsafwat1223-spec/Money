import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/transaction_entity.dart';
import '../common/widgets.dart';
import 'transactions_providers.dart';

class TransactionsScreen extends ConsumerWidget {
  const TransactionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final async = ref.watch(transactionsListProvider);

    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('حدث خطأ: $e')),
      data: (view) {
        if (view.transactions.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(AppLucideIcons.inbox, size: 44, color: c.textLight),
                const SizedBox(height: AppSpacing.s3),
                Text('لا توجد عمليات',
                    style: AppTypography.headline(c.textMain)),
              ],
            ),
          );
        }

        // تجميع حسب عنوان التاريخ مع الحفاظ على الترتيب.
        final groups = <String, List<TransactionEntity>>{};
        for (final tx in view.transactions) {
          final label = Formatters.dateGroupLabel(tx.occurredAt);
          groups.putIfAbsent(label, () => []).add(tx);
        }

        return ListView(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutter, AppSpacing.s4, AppSpacing.gutter, 120),
          children: [
            for (final entry in groups.entries) ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.s2),
                child: Text('── ${entry.key} ──',
                    style: AppTypography.subhead(c.textLight)),
              ),
              for (final tx in entry.value)
                TransactionRow(
                  transaction: tx,
                  category: view.catalog.byId(tx.categoryId),
                  onTap: () => context.push('/transaction/${tx.id}'),
                ),
            ],
          ],
        );
      },
    );
  }
}
