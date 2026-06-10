import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/transaction_entity.dart';
import 'category_catalog.dart';

/// دائرة أيقونة تصنيف متوهجة بإطار ناعم بلون التصنيف.
class CategoryAvatar extends StatelessWidget {
  const CategoryAvatar({super.key, required this.category, this.size = 44});

  final CategoryView? category;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = category?.color ?? c.textLight;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: color.withValues(alpha: 0.25),
          width: 1.2,
        ),
      ),
      child: Icon(
        category?.icon ?? AppLucideIcons.shapes,
        color: color,
        size: size * 0.46,
      ),
    );
  }
}

/// صف عملية فخم مصمم كبطاقة زجاجية عائمة.
class TransactionRow extends StatelessWidget {
  const TransactionRow({
    super.key,
    required this.transaction,
    required this.category,
    this.onTap,
  });

  final TransactionEntity transaction;
  final CategoryView? category;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isIncome = transaction.type == TransactionTypeEntity.income ||
        transaction.type == TransactionTypeEntity.refund;
    
    // استخدام اللون الأحمر للمصاريف والأخضر للأرباح لتسهيل التمييز البصري
    final amountColor = isIncome ? c.success : c.danger;
    final pending = transaction.status == TransactionStatus.pending;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 5),
      decoration: BoxDecoration(
        color: c.surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: c.primary.withValues(alpha: 0.1),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                CategoryAvatar(category: category, size: 44),
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
                              style: AppTypography.bodyStrong(c.textMain).copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (pending) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: c.accent.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: c.accent.withValues(alpha: 0.35),
                                  width: 0.8,
                                ),
                              ),
                              child: Text(
                                'معلّقة',
                                style: AppTypography.caption(c.accent).copyWith(
                                  fontSize: 9.0,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${category?.nameAr ?? '—'} · ${Formatters.time(transaction.occurredAt)}',
                        style: AppTypography.caption(c.textLight),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  '${Formatters.signed(transaction.amount, isExpense: !isIncome)} ${transaction.currency}',
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
