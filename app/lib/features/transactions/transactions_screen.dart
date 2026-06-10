import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/transaction_entity.dart';
import '../common/section_hero_header.dart';
import '../common/widgets.dart';
import 'transaction_details_screen.dart';
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
          return ListView(
            padding: EdgeInsets.zero,
            children: [
              const SectionHeroHeader(
                title: 'العمليات',
                subtitle: 'كل عملية محفوظة محلياً، مع التصنيف والمصدر والحالة.',
                metrics: [
                  SectionHeroMetric(value: '0', label: 'عمليات'),
                  SectionHeroMetric(value: '0', label: 'بانتظار التأكيد'),
                  SectionHeroMetric(value: '0 ر', label: 'إجمالي'),
                ],
              ),
              Padding(
                padding: const EdgeInsets.all(AppSpacing.gutter),
                child: Column(
                  children: [
                    Icon(AppLucideIcons.inbox, size: 44, color: c.textLight),
                    const SizedBox(height: AppSpacing.s3),
                    Text('لا توجد عمليات',
                        style: AppTypography.headline(c.textMain)),
                  ],
                ),
              ),
              ],
            );
        }

        final pending = view.transactions
            .where((tx) => tx.status == TransactionStatus.pending)
            .length;
        final total = view.transactions
            .where((tx) =>
                tx.type == TransactionTypeEntity.payment ||
                tx.type == TransactionTypeEntity.withdrawal)
            .fold<double>(0, (sum, tx) => sum + tx.amount);
        final groups = <String, List<TransactionEntity>>{};
        for (final tx in view.transactions) {
          final label = Formatters.dateGroupLabel(tx.occurredAt);
          groups.putIfAbsent(label, () => []).add(tx);
        }

        return ListView(
          padding: EdgeInsets.zero,
          children: [
            SectionHeroHeader(
              title: 'العمليات',
              subtitle: 'راجع آخر عملياتك وافتح التفاصيل من أسفل الشاشة.',
              metrics: [
                SectionHeroMetric(
                    value: '${view.transactions.length}', label: 'عمليات'),
                SectionHeroMetric(value: '$pending', label: 'بانتظار التأكيد'),
                SectionHeroMetric(
                    value: '${Formatters.integer(total)} ر', label: 'مصروف'),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.gutter, AppSpacing.s4, AppSpacing.gutter, 120),
              child: Column(
                children: [
                  for (final entry in groups.entries) ...[
                    Padding(
                      padding: const EdgeInsets.only(
                          top: AppSpacing.s4, bottom: AppSpacing.s2),
                      child: Row(
                        children: [
                          Text(
                            entry.key,
                            style: AppTypography.subhead(c.primary).copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Container(
                              height: 1,
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    c.primary.withValues(alpha: 0.25),
                                    c.primary.withValues(alpha: 0.0),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    for (final tx in entry.value)
                      TransactionRow(
                        transaction: tx,
                        category: view.catalog.byId(tx.categoryId),
                        onTap: () =>
                            TransactionDetailsScreen.showSheet(context, tx.id),
                      ),
                  ],
                ],
              ),
            ),
          ],
          );
      },
    );
  }
}
