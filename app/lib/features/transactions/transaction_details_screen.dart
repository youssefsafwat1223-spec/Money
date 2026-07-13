import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/transaction_entity.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../cards/brand_mark.dart';
import '../common/category_catalog.dart';
import '../common/transaction_direction.dart';
import '../common/widgets.dart';
import '../common/app_sheet_scaffold.dart';
import '../common/app_screen_scaffold.dart';
import '../common/app_header.dart';
import '../common/app_card.dart';
import '../common/app_button.dart';
import '../../core/di/app_providers.dart';
import '../dashboard/dashboard_providers.dart';
import '../subscriptions/subscriptions_providers.dart';
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
          _buildScaffold(context, c, const Center(child: Text('حدث خطأ'))),
      data: (tx) {
        if (tx == null) {
          return _buildScaffold(
              context, c, const Center(child: Text('العملية غير موجودة')));
        }

        final category = catalog?.byId(tx.categoryId);
        final isDebit = transactionIsDebit(tx);
        final amountColor = isDebit ? c.danger : c.success;
        final merchantTitle = tx.rawMerchant?.trim().isNotEmpty == true
            ? tx.rawMerchant!.trim()
            : category?.nameAr ?? 'عملية';
        final statusColor = switch (tx.status) {
          TransactionStatus.confirmed => c.success,
          TransactionStatus.pending => c.accent,
          TransactionStatus.ignored => c.textMuted,
        };
        final statusLabel = switch (tx.status) {
          TransactionStatus.confirmed => 'مؤكدة',
          TransactionStatus.pending => 'تحتاج مراجعة',
          TransactionStatus.ignored => 'متجاهلة',
        };
        final editButton = IconButton(
          tooltip: 'تعديل العملية',
          onPressed: () => ManualTransactionSheet.show(
            context,
            transaction: tx,
          ),
          icon: Icon(Icons.edit_outlined, color: c.textPrimary),
        );

        final body = Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            AppSpacing.s2,
            AppSpacing.gutter,
            AppSpacing.s6,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppCard(
                padding: const EdgeInsets.all(AppSpacing.s4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: amountColor.withValues(alpha: 0.18),
                              width: 2,
                            ),
                          ),
                          child: (tx.rawMerchant != null &&
                                  BrandMark.hasBrand(tx.rawMerchant!))
                              ? BrandMark(name: tx.rawMerchant!, size: 58)
                              : CategoryAvatar(category: category, size: 58),
                        ),
                        const SizedBox(width: AppSpacing.s3),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                merchantTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppTypography.headline(c.textPrimary)
                                    .copyWith(fontWeight: FontWeight.w800),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                category?.nameAr ?? 'غير مصنّف',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppTypography.caption(c.textSecondary),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: AppSpacing.s2),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 9, vertical: 4),
                          decoration: BoxDecoration(
                            color: statusColor.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(AppRadius.pill),
                          ),
                          child: Text(
                            statusLabel,
                            style: AppTypography.caption(statusColor)
                                .copyWith(fontWeight: FontWeight.w800),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.s4),
                    AnimatedAmountText(
                      amount: (tx.amount == 0 && tx.foreignAmount != null)
                          ? tx.foreignAmount!
                          : tx.amount,
                      color: amountColor,
                      suffix: (tx.amount == 0 && tx.foreignAmount != null)
                          ? ' ${tx.foreignCurrency}'
                          : ' ${Currency.arabicLabel(tx.currency)}',
                      style: AppTypography.amountHero(amountColor),
                    ),
                    const SizedBox(height: AppSpacing.s2),
                    Text(
                      '${Formatters.dateWithWeekday(tx.occurredAt, context)} · ${Formatters.time(tx.occurredAt)}',
                      textAlign: TextAlign.center,
                      style: AppTypography.caption(c.textSecondary),
                    ),
                    if (tx.amount == 0 &&
                        tx.foreignAmount != null &&
                        tx.foreignCurrency != null) ...[
                      const SizedBox(height: AppSpacing.s3),
                      AppButton(
                        label:
                            'أضف القيمة بـ ${Currency.arabicLabel(tx.currency)}',
                        onPressed: () => _promptForPrice(context, ref, tx),
                        isPrimary: true,
                        height: 42,
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
                      'العملة',
                      Currency.arabicLabel(tx.currency),
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
                data: Theme.of(context)
                    .copyWith(dividerColor: Colors.transparent),
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
              const SizedBox(height: AppSpacing.s4),
              if (tx.status != TransactionStatus.confirmed) ...[
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () => _confirmTransaction(context, ref, tx.id),
                    icon: const Icon(Icons.verified_outlined),
                    label: Text(
                      tx.status == TransactionStatus.ignored
                          ? 'تأكيد العملية المتجاهلة'
                          : 'تأكيد العملية',
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.s2),
              ],
              TextButton.icon(
                onPressed: () => _confirmDelete(context, ref, tx.id),
                icon: Icon(Icons.delete_outline_rounded, color: c.danger),
                label: Text('حذف العملية',
                    style: AppTypography.bodyStrong(c.danger)),
              ),
            ],
          ),
        );

        return _buildScaffold(context, c, body,
            title: 'تفاصيل العملية', trailing: editButton);
      },
    );
  }

  Future<void> _confirmTransaction(
      BuildContext context, WidgetRef ref, String id) async {
    await ref.read(confirmTransactionUseCaseProvider)(id);
    ref.invalidate(transactionByIdProvider(id));
    refreshTransactions(ref);
    ref.invalidate(dashboardDataProvider);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('تم تأكيد العملية.')),
    );
  }

  Future<void> _confirmDelete(
      BuildContext context, WidgetRef ref, String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف العملية؟'),
        content: const Text('هتتشال من تقاريرك ورصيدك. مش هتقدر تتراجع.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('حذف', style: TextStyle(color: ctx.colors.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(transactionRepositoryProvider).deleteTransaction(id);
    } on RepoException catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(repoExceptionMessage(e))),
      );
      return;
    }
    final affectedBillIds =
        await ref.read(billRepositoryProvider).deletePaymentForTransaction(id);
    for (final billId in affectedBillIds) {
      ref.invalidate(billPaymentsProvider(billId));
    }
    if (affectedBillIds.isNotEmpty) {
      ref.invalidate(savedBillsProvider);
      ref.invalidate(billsViewProvider);
    }
    refreshTransactions(ref);
    ref.invalidate(dashboardDataProvider);
    if (context.mounted) Navigator.of(context).pop();
  }

  Widget _buildScaffold(BuildContext context, AppColors c, Widget body,
      {String? title, Widget? trailing}) {
    if (isSheet) {
      return AppSheetScaffold(
        title: title ?? 'تفاصيل العملية',
        trailing: trailing,
        leading: IconButton(
          tooltip: 'إغلاق',
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
        body: SingleChildScrollView(child: body),
      );
    }
  }

  String _pendingLabel(DateTime createdAt) {
    final days = DateTime.now().difference(createdAt).inDays;
    if (days == 0) return 'غير مؤكدة · اليوم';
    if (days == 1) return 'غير مؤكدة · منذ يوم';
    return 'غير مؤكدة · منذ $days أيام';
  }

  /// Prompts for the home-currency value of a foreign spend that is still
  /// "awaiting pricing" (amount 0), then stores it so it counts in totals.
  Future<void> _promptForPrice(
    BuildContext context,
    WidgetRef ref,
    TransactionEntity tx,
  ) async {
    final controller = TextEditingController();
    final value = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('القيمة بالريال'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: 'المبلغ بـ ${Currency.arabicLabel(tx.currency)}',
            hintText: '${Formatters.amount(tx.foreignAmount ?? 0)} '
                '${tx.foreignCurrency ?? ''}',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(ctx).pop(double.tryParse(controller.text.trim())),
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
    // Do NOT dispose controller here – the dialog's exit animation may still
    // reference it. It will be GC'd when the method scope ends.
    if (value == null || value <= 0) return;
    try {
      await ref
          .read(transactionRepositoryProvider)
          .updateAmount(transactionId: tx.id, amount: value);
    } on RepoException catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(repoExceptionMessage(e))),
      );
      return;
    }
    ref.invalidate(transactionByIdProvider(tx.id));
    refreshTransactions(ref);
    ref.invalidate(dashboardDataProvider);
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
