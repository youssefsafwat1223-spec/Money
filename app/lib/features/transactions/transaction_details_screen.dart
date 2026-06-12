import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/transaction_entity.dart';
import '../common/category_catalog.dart';
import '../common/widgets.dart';
import 'transactions_providers.dart';
import 'widgets/change_category_sheet.dart';
import '../common/motion.dart';

class TransactionDetailsScreen extends ConsumerWidget {
  const TransactionDetailsScreen({super.key, required this.transactionId});

  final String transactionId;

  static const _typeLabels = {
    TransactionTypeEntity.payment: 'شراء',
    TransactionTypeEntity.withdrawal: 'سحب نقدي',
    TransactionTypeEntity.transfer: 'تحويل',
    TransactionTypeEntity.refund: 'استرداد',
    TransactionTypeEntity.income: 'دخل',
    TransactionTypeEntity.unknown: 'غير محدد',
  };

  static const _sourceLabels = {
    TransactionSourceEntity.bank: 'بنك',
    TransactionSourceEntity.card: 'بطاقة',
    TransactionSourceEntity.wallet: 'محفظة',
    TransactionSourceEntity.unknown: 'غير محدد',
  };

  static Future<void> showSheet(BuildContext context, String transactionId) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _TransactionDetailsSheet(transactionId: transactionId),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: SafeArea(child: _TransactionDetailsContent(transactionId: transactionId, isSheet: false)),
    );
  }
}

class _TransactionDetailsSheet extends StatelessWidget {
  const _TransactionDetailsSheet({required this.transactionId});

  final String transactionId;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Material(
            color: isDark ? c.surface.withValues(alpha: 0.9) : Colors.white.withValues(alpha: 0.92),
            shape: RoundedRectangleBorder(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              side: BorderSide(
                color: Colors.white.withValues(alpha: isDark ? 0.08 : 0.3),
                width: 1.5,
              ),
            ),
            child: Container(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.92,
              ),
              child: _TransactionDetailsContent(transactionId: transactionId, isSheet: true),
            ),
          ),
        ),
      ),
    );
  }
}


class _TransactionDetailsContent extends ConsumerWidget {
  const _TransactionDetailsContent({required this.transactionId, required this.isSheet});

  final String transactionId;
  final bool isSheet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final txAsync = ref.watch(transactionByIdProvider(transactionId));
    final catalog = ref.watch(categoryCatalogProvider).valueOrNull;

    return txAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('حدث خطأ: $e')),
      data: (tx) {
        if (tx == null) {
          return const Center(child: Text('العملية غير موجودة'));
        }
        final category = catalog?.byId(tx.categoryId);
        final containerColor = isDark
            ? c.surface2.withValues(alpha: 0.4)
            : c.surface2.withValues(alpha: 0.6);
        final containerBorderColor = c.border.withValues(alpha: 0.5);

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isSheet) ...[
              // Drag handle
              Container(
                margin: const EdgeInsets.only(top: 12, bottom: 8),
                width: 40,
                height: 4.5,
                decoration: BoxDecoration(
                  color: c.textLight.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(2.5),
                ),
              ),
            ],
            // Top Bar
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.gutter,
                vertical: AppSpacing.s2,
              ),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: Icon(Icons.close, color: c.textMain),
                    style: IconButton.styleFrom(
                      backgroundColor: isDark ? c.surface2 : c.bg,
                      padding: const EdgeInsets.all(8),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      'تفاصيل العملية',
                      textAlign: TextAlign.center,
                      style: AppTypography.headline(c.textMain),
                    ),
                  ),
                  const SizedBox(width: 48), // Balancing close button
                ],
              ),
            ),
            Divider(height: 1, color: c.border),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.gutter,
                  AppSpacing.s4,
                  AppSpacing.gutter,
                  AppSpacing.s6,
                ),
                children: [
                  // Hero section (Avatar & Amount)
                  Center(
                    child: Column(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: c.primary.withValues(alpha: 0.1),
                              width: 2,
                            ),
                          ),
                          child: CategoryAvatar(category: category, size: 78),
                        ),
                        const SizedBox(height: AppSpacing.s3),
                        AnimatedAmountText(
                          amount: tx.amount,
                          color: c.textMain,
                          suffix: ' ${tx.currency}',
                          style: AppTypography.amountHero(c.textMain),
                        ),
                        if (tx.rawMerchant != null) ...[
                          const SizedBox(height: AppSpacing.s1),
                          Text(
                            tx.rawMerchant!,
                            textAlign: TextAlign.center,
                            style: AppTypography.headline(c.textMain).copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.s6),
                  
                  // Details Card
                  Container(
                    decoration: BoxDecoration(
                      color: containerColor,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: containerBorderColor, width: 1),
                    ),
                    child: Column(
                      children: [
                        _buildDetailRow(
                          context,
                          'التصنيف',
                          category?.nameAr ?? 'غير مصنّف',
                          trailing: catalog == null
                              ? null
                              : _buildChangeButton(context, tx, catalog),
                        ),
                        _divider(c),
                        _buildDetailRow(
                          context,
                          'النوع',
                          TransactionDetailsScreen._typeLabels[tx.type] ?? '—',
                        ),
                        _divider(c),
                        _buildDetailRow(
                          context,
                          'المصدر',
                          '${TransactionDetailsScreen._sourceLabels[tx.source] ?? '—'}${tx.cardLast4 != null ? ' · ${tx.cardLast4}' : ''}',
                        ),
                        _divider(c),
                        _buildDetailRow(
                          context,
                          'التاريخ',
                          '${Formatters.fullDate(tx.occurredAt)} · ${Formatters.time(tx.occurredAt)}',
                        ),
                        if (tx.balanceAfter != null) ...[
                          _divider(c),
                          _buildDetailRow(
                            context,
                            'الرصيد بعد',
                            '${Formatters.amount(tx.balanceAfter!)} ${tx.currency}',
                          ),
                        ],
                        if (tx.status == TransactionStatus.pending) ...[
                          _divider(c),
                          _buildDetailRow(
                            context,
                            'الحالة',
                            'غير مؤكدة',
                            isPending: true,
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.s4),

                  // Raw text
                  Theme(
                    data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                    child: ExpansionTile(
                      tilePadding: const EdgeInsets.symmetric(horizontal: 8),
                      title: Text('النص الأصلي', style: AppTypography.subhead(c.textLight)),
                      collapsedIconColor: c.textLight,
                      iconColor: c.primary,
                      children: [
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: containerColor,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: containerBorderColor, width: 1),
                          ),
                          child: SelectableText(
                            tx.rawMessage,
                            style: AppTypography.footnote(c.textMain).copyWith(height: 1.4),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildDetailRow(BuildContext context, String label, String value,
      {Widget? trailing, bool isPending = false}) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: AppTypography.subhead(c.textLight).copyWith(fontWeight: FontWeight.w500),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: AppTypography.bodyStrong(isPending ? c.accent : c.textMain),
            ),
          ),
          if (trailing != null) trailing,
        ],
      ),
    );
  }

  Widget _divider(AppColors c) {
    return Divider(
      height: 1,
      thickness: 1,
      color: c.border.withValues(alpha: 0.3),
      indent: 20,
      endIndent: 20,
    );
  }

  Widget _buildChangeButton(
      BuildContext context, TransactionEntity tx, CategoryCatalog catalog) {
    final c = context.colors;
    return Material(
      color: c.primary.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(100),
      child: InkWell(
        onTap: () => showChangeCategorySheet(context, tx, catalog),
        borderRadius: BorderRadius.circular(100),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(100),
            border: Border.all(color: c.primary.withValues(alpha: 0.15), width: 1),
          ),
          child: Text(
            'تغيير',
            style: AppTypography.subhead(c.primary).copyWith(fontSize: 12),
          ),
        ),
      ),
    );
  }
}
