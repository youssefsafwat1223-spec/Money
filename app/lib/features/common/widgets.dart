import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/transaction_entity.dart';
import 'category_catalog.dart';

/// دائرة تعرض شعار التاجر (الحرف الأول) أو أيقونة التصنيف.
class CategoryAvatar extends StatelessWidget {
  const CategoryAvatar({
    super.key, 
    this.merchantName, 
    required this.category, 
    this.size = 44,
  });

  final String? merchantName;
  final CategoryView? category;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = category?.color ?? c.primary;
    
    // محاولة استخراج الحرف الأول من اسم التاجر
    String? initial;
    if (merchantName != null && merchantName!.trim().isNotEmpty) {
      final text = merchantName!.trim();
      // استخراج أول حرف غير مسافة
      if (text.isNotEmpty) {
        initial = text.characters.first.toUpperCase();
      }
    }

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: initial != null ? c.surface : color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(size * 0.35),
        border: Border.all(
          color: initial != null ? c.border : color.withValues(alpha: 0.25),
          width: 1.2,
        ),
      ),
      alignment: Alignment.center,
      child: initial != null
          ? Text(
              initial,
              style: AppTypography.title2(c.textMain).copyWith(
                fontWeight: FontWeight.bold,
                fontSize: size * 0.45,
              ),
            )
          : Icon(
              category?.icon ?? AppLucideIcons.shapes,
              color: color,
              size: size * 0.46,
            ),
    );
  }
}

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
    final isIncome = transaction.type == TransactionTypeEntity.income ||
        transaction.type == TransactionTypeEntity.refund;

    final amountColor = isIncome ? c.success : c.textMain;
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
                              style:
                                  AppTypography.bodyStrong(c.textMain).copyWith(
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
                                color: c.textLight.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                'معلّقة',
                                style: AppTypography.caption(c.textLight).copyWith(
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
                  hideAmount
                      ? '•••• ${transaction.currency}'
                      : '${Formatters.signed(transaction.amount, isExpense: !isIncome)} ${transaction.currency}',
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
