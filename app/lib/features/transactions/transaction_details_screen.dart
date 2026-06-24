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
import '../common/app_sheet_scaffold.dart';
import '../common/app_screen_scaffold.dart';
import '../common/app_header.dart';
import '../common/app_card.dart';
import '../common/app_button.dart';
import 'manual_transaction_sheet.dart';
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
    TransactionSourceEntity.aiParsed: 'ذكاء اصطناعي',
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
    return _TransactionDetailsContent(
        transactionId: transactionId, isSheet: false);
  }
}

class _TransactionDetailsSheet extends StatelessWidget {
  const _TransactionDetailsSheet({required this.transactionId});

  final String transactionId;

  @override
  Widget build(BuildContext context) {
    return _TransactionDetailsContent(
        transactionId: transactionId, isSheet: true);
  }
}

class _TransactionDetailsContent extends ConsumerWidget {
  const _TransactionDetailsContent(
      {required this.transactionId, required this.isSheet});

  final String transactionId;
  final bool isSheet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final txAsync = ref.watch(transactionByIdProvider(transactionId));
    final catalog = ref.watch(categoryCatalogProvider).valueOrNull;

    return txAsync.when(
      loading: () => _buildScaffold(
          context, c, const Center(child: CircularProgressIndicator())),
      error: (e, _) =>
          _buildScaffold(context, c, Center(child: Text('حدث خطأ: $e'))),
      data: (tx) {
        if (tx == null) {
          return _buildScaffold(
              context, c, const Center(child: Text('العملية غير موجودة')));
        }

        final category = catalog?.byId(tx.categoryId);
        final editButton = IconButton(
          onPressed: () => ManualTransactionSheet.show(
            context,
            transaction: tx,
          ),
          icon: Icon(Icons.edit_outlined, color: c.textPrimary),
        );

        final body = ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            AppSpacing.s2,
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
                    color: _isDebit(tx.type) ? c.danger : c.success,
                    suffix: ' ${tx.currency}',
                    style: AppTypography.amountHero(c.textPrimary),
                  ),
                  if (tx.rawMerchant != null) ...[
                    const SizedBox(height: AppSpacing.s1),
                    Text(
                      tx.rawMerchant!,
                      textAlign: TextAlign.center,
                      style: AppTypography.headline(c.textPrimary).copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.s6),

            // Details Card
            AppCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  _buildDetailRow(
                    context,
                    'التصنيف',
                    category?.nameAr ?? 'غير مصنّف',
                    trailing: catalog == null
                        ? null
                        : AppButton(
                            label: 'تغيير',
                            onPressed: () =>
                                showChangeCategorySheet(context, tx, catalog),
                            isPrimary: false,
                            height: 32,
                          ),
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
                    '${Formatters.fullDate(tx.occurredAt, context)} · ${Formatters.time(tx.occurredAt)}',
                  ),
                  if (tx.foreignAmount != null &&
                      tx.foreignCurrency != null) ...[
                    _divider(c),
                    _buildDetailRow(
                      context,
                      'بالعملة الأصلية',
                      '${Formatters.amount(tx.foreignAmount!)} ${tx.foreignCurrency!}',
                    ),
                  ],
                  if (tx.balanceAfter != null) ...[
                    _divider(c),
                    _buildDetailRow(
                      context,
                      'الرصيد بعد',
                      '${Formatters.amount(tx.balanceAfter!)} ${tx.currency}',
                    ),
                  ],
                  if (tx.note != null && tx.note!.isNotEmpty) ...[
                    _divider(c),
                    _buildDetailRow(
                      context,
                      'ملاحظة',
                      tx.note!,
                    ),
                  ],
                  if (tx.status == TransactionStatus.pending) ...[
                    _divider(c),
                    _buildDetailRow(
                      context,
                      'الحالة',
                      _pendingLabel(tx.createdAt),
                      isPending: true,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.s4),

            // Raw text
            Theme(
              data:
                  Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: const EdgeInsets.symmetric(horizontal: 8),
                title: Text('النص الأصلي',
                    style: AppTypography.subhead(c.textSecondary)),
                collapsedIconColor: c.textSecondary,
                iconColor: c.primary,
                children: [
                  AppCard(
                    padding: const EdgeInsets.all(16),
                    child: SizedBox(
                      width: double.infinity,
                      child: SelectableText(
                        tx.rawMessage,
                        style: AppTypography.footnote(c.textPrimary)
                            .copyWith(height: 1.4),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );

        return _buildScaffold(context, c, body,
            title: 'تفاصيل العملية', trailing: editButton);
      },
    );
  }

  Widget _buildScaffold(BuildContext context, AppColors c, Widget body,
      {String? title, Widget? trailing}) {
    if (isSheet) {
      return AppSheetScaffold(
        title: title ?? 'تفاصيل العملية',
        trailing: trailing,
        leading: IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: Icon(Icons.close, color: c.textSecondary),
        ),
        scrollable: true,
        body: body,
      );
    } else {
      return AppScreenScaffold(
        header: AppHeader(
          title: title ?? 'تفاصيل العملية',
          action: trailing,
          showBack: true,
        ),
        body: body,
      );
    }
  }

  bool _isDebit(TransactionTypeEntity type) =>
      type != TransactionTypeEntity.income &&
      type != TransactionTypeEntity.refund;

  String _pendingLabel(DateTime createdAt) {
    final days = DateTime.now().difference(createdAt).inDays;
    if (days == 0) return 'غير مؤكدة · اليوم';
    if (days == 1) return 'غير مؤكدة · منذ يوم';
    return 'غير مؤكدة · منذ $days أيام';
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
              style: AppTypography.subhead(c.textSecondary)
                  .copyWith(fontWeight: FontWeight.w500),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: AppTypography.bodyStrong(
                  isPending ? c.accent : c.textPrimary),
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
      color: c.border.withValues(alpha: 0.5),
      indent: 20,
      endIndent: 20,
    );
  }
}
