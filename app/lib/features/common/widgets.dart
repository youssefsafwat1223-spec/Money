import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/transaction_entity.dart';
import 'category_catalog.dart';
import 'category_avatar.dart';
import 'transaction_direction.dart';

export 'app_error_state.dart';
export 'app_budget_progress_card.dart';
export 'app_button.dart';
export 'app_card.dart';
export 'app_category_chip.dart';
export 'app_empty_state.dart';
export 'app_header.dart';
export 'app_insight_card.dart';
export 'app_loading_state.dart';
export 'app_metric_card.dart';
export 'app_pill_tab_bar.dart';
export 'app_screen_scaffold.dart';
export 'app_sheet_scaffold.dart';
export 'app_status_pill.dart';
export 'app_transaction_row.dart';
export 'category_avatar.dart';
export 'charts/spending_charts.dart';
export 'section_hero_header.dart';
export 'section_header.dart';
export 'chart_card.dart';
export 'vault_widget.dart';
export 'widgets/announcement_banner.dart';

/// صف عملية فخم مصمم بأسلوب الحد الأدنى.
class TransactionRow extends StatelessWidget {
  const TransactionRow({
    super.key,
    required this.transaction,
    required this.category,
    this.onTap,
    this.hideAmount = false,
  });

  final TransactionEntity transaction;
  final CategoryView? category;
  final VoidCallback? onTap;
  final bool hideAmount;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDebit = transactionIsDebit(transaction);

    final amountColor = isDebit ? c.textPrimary : c.success;
    final pending = transaction.status == TransactionStatus.pending;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 5),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: c.border,
          width: 1.0,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                CategoryAvatar(
                  merchantName: transaction.rawMerchant,
                  category: category,
                  size: 44,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              transaction.rawMerchant ??
                                  category?.nameAr ??
                                  'عملية',
                              style: AppTypography.bodyStrong(c.textPrimary)
                                  .copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (pending) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: c.warning.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                'معلّقة',
                                style:
                                    AppTypography.caption(c.warning).copyWith(
                                  fontSize: 11.0,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                          if (transaction.source ==
                              TransactionSourceEntity.aiParsed) ...[
                            const SizedBox(width: 4),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 5, vertical: 2),
                              decoration: BoxDecoration(
                                color: c.accent.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: c.accent.withValues(alpha: 0.35),
                                  width: 0.8,
                                ),
                              ),
                              child: Text(
                                'AI',
                                style: AppTypography.caption(c.accent).copyWith(
                                  fontSize: 11.0,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${category?.nameAr ?? '—'} · ${Formatters.time(transaction.occurredAt)}',
                        style: AppTypography.caption(c.textMuted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  hideAmount
                      ? '•••• ${transaction.currency}'
                      : '${Formatters.signed(transaction.amount, isExpense: isDebit)} ${transaction.currency}',
                  style: AppTypography.bodyStrong(amountColor).copyWith(
                    fontWeight: FontWeight.bold,
                    letterSpacing: -0.2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
