import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/utils/async_reload_safe.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/navy_sheet_theme.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/bill_entity.dart';
import '../../domain/entities/transaction_entity.dart';
import '../../domain/repositories/transaction_repository.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../../domain/finance/bill_metrics.dart';
import '../../engine/categorization/category.dart';
import '../cards/brand_mark.dart';
import '../common/app_card.dart';
import '../common/app_sheet_scaffold.dart';
import '../dashboard/dashboard_providers.dart';
import '../transactions/transaction_details_screen.dart';
import '../transactions/transactions_providers.dart';
import 'bill_form_sheet.dart';
import 'bill_payment_attempt.dart';
import 'subscriptions_providers.dart';
import '../../core/theme/widgets/app_toast.dart';

class BillDetailsSheet extends ConsumerWidget {
  const BillDetailsSheet({super.key, required this.bill});

  final BillEntity bill;

  static Future<void> show(BuildContext context, BillEntity bill) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => navySheetTheme(BillDetailsSheet(bill: bill)),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final currentBill = ref.watch(savedBillsProvider).dataOrWhen(
          data: (bills) {
            for (final item in bills) {
              if (item.id == bill.id) return item;
            }
            return bill;
          },
          orElse: () => bill,
        );
    final paymentsAsync = ref.watch(billPaymentsProvider(currentBill.id));
    final isInstallment = currentBill.type == BillType.installment;
    final currLabel = Currency.arabicLabel(currentBill.currency);
    final accountName = ref.watch(accountsProvider).dataOrWhen(
          data: (accounts) {
            final matches = accounts
                .where((account) => account.id == currentBill.accountId);
            return matches.isEmpty ? null : matches.first.name;
          },
          orElse: () => null,
        );
    return AppSheetScaffold(
      title: currentBill.name,
      subtitle: isInstallment ? 'قسط' : 'اشتراك',
      scrollable: true,
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
        child: FutureBuilder<List<TransactionEntity>>(
          future: _loadBillTransactions(ref, currentBill),
          builder: (context, snapshot) {
            final transactions = snapshot.data ?? const <TransactionEntity>[];
            final payments =
                paymentsAsync.valueOrNull ?? const <BillPaymentEntity>[];
            // MALI-064n: bill_payments is the authoritative ledger — one real
            // payment counts once. Fuzzy name-matched transactions are NOT
            // summed; the unlinked ones are shown only as link suggestions.
            final paidSummary = billPaidTotal(
              payments: payments,
              manualPaidAmount: currentBill.safeManualPaidAmount,
            );
            final legacyManualPaid = paidSummary.legacyManual;
            final totalPaid = paidSummary.total;
            final linkedTxIds = linkedTransactionIds(payments);
            final suggestedTransactions = transactions
                .where((tx) => !linkedTxIds.contains(tx.id))
                .toList(growable: false);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    BrandMark(
                        name: currentBill.lenderName ?? currentBill.name,
                        size: 54),
                    const SizedBox(width: AppSpacing.s3),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_statusLabel(currentBill),
                              style: AppTypography.bodyStrong(
                                  _statusColor(context, currentBill))),
                          const SizedBox(height: 2),
                          Text(
                            [
                              _frequencyLabel(currentBill.frequency),
                              _dueLabel(currentBill.nextDueDate),
                              if (accountName != null) accountName,
                            ].join(' · '),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: AppTypography.caption(c.textSecondary),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.s4),
                AppCard(
                  padding: const EdgeInsets.all(AppSpacing.s3),
                  child: Row(
                    children: [
                      Expanded(
                        child: _SummaryTile(
                          label: isInstallment ? 'قيمة القسط' : 'المبلغ',
                          value:
                              '${Formatters.amount(currentBill.amount)} $currLabel',
                        ),
                      ),
                      Container(width: 1, height: 38, color: c.border),
                      Expanded(
                        child: _SummaryTile(
                          label: 'إجمالي مدفوع',
                          value: '${Formatters.amount(totalPaid)} $currLabel',
                        ),
                      ),
                      Container(width: 1, height: 38, color: c.border),
                      Expanded(
                        child: _SummaryTile(
                          label: 'دفعات مسجّلة',
                          value: '${payments.length}',
                        ),
                      ),
                    ],
                  ),
                ),
                if (legacyManualPaid > 0) ...[
                  const SizedBox(height: AppSpacing.s2),
                  Text(
                    'يشمل ${Formatters.amount(legacyManualPaid)} $currLabel مدفوعة يدويًا قديمة.',
                    textAlign: TextAlign.center,
                    style: AppTypography.caption(c.textSecondary),
                  ),
                ],
                if (isInstallment && currentBill.totalInstallments != null) ...[
                  const SizedBox(height: AppSpacing.s3),
                  AppCard(
                    padding: const EdgeInsets.all(AppSpacing.s3),
                    child: Row(
                      children: [
                        Expanded(
                          child: _SummaryTile(
                            label: 'مدفوع',
                            value:
                                '${currentBill.paidCount ?? 0} من ${currentBill.totalInstallments}',
                          ),
                        ),
                        Container(width: 1, height: 38, color: c.border),
                        Expanded(
                          child: _SummaryTile(
                            label: 'متبقي',
                            value: '${currentBill.remainingInstallments}',
                          ),
                        ),
                        Container(width: 1, height: 38, color: c.border),
                        Expanded(
                          child: _SummaryTile(
                            label: 'تقدم',
                            value:
                                '${(currentBill.installmentProgress * 100).round()}%',
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: AppSpacing.s4),
                FilledButton.icon(
                  onPressed: () => _showRecordPayment(
                    context,
                    ref,
                    currentBill,
                  ),
                  icon: const Icon(Icons.add_card_outlined),
                  label: Text(isInstallment ? 'تسجيل دفع قسط' : 'تسجيل دفعة'),
                ),
                const SizedBox(height: AppSpacing.s3),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () =>
                            BillFormSheet.show(context, bill: currentBill),
                        icon: const Icon(Icons.edit_outlined),
                        label: const Text('تعديل'),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.s3),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () =>
                            _confirmDelete(context, ref, currentBill),
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('حذف'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: c.danger,
                          side: BorderSide(
                              color: c.danger.withValues(alpha: 0.45)),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.s5),
                Text('سجل الدفعات',
                    style: AppTypography.bodyStrong(c.textPrimary)),
                const SizedBox(height: AppSpacing.s2),
                if (paymentsAsync.isLoading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: AppSpacing.s4),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (payments.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(AppSpacing.s3),
                    decoration: BoxDecoration(
                      color: c.surfaceCard,
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      border: Border.all(color: c.border),
                    ),
                    child: Text(
                      isInstallment
                          ? 'لسه مفيش دفعات أقساط مسجلة يدويًا.'
                          : 'لسه مفيش دفعات اشتراك مسجلة يدويًا.',
                      textAlign: TextAlign.center,
                      style: AppTypography.caption(c.textSecondary),
                    ),
                  )
                else
                  for (final payment in payments)
                    _BillPaymentRow(payment: payment, bill: currentBill),
                const SizedBox(height: AppSpacing.s5),
                Text('عمليات مقترحة للربط',
                    style: AppTypography.bodyStrong(c.textPrimary)),
                const SizedBox(height: 2),
                Text(
                  'مطابقة بالاسم — لا تُحتسب ضمن المدفوع حتى تربطها كدفعة.',
                  style: AppTypography.caption(c.textSecondary),
                ),
                const SizedBox(height: AppSpacing.s2),
                if (snapshot.connectionState == ConnectionState.waiting)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: AppSpacing.s4),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (suggestedTransactions.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(AppSpacing.s3),
                    decoration: BoxDecoration(
                      color: c.surfaceCard,
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      border: Border.all(color: c.border),
                    ),
                    child: Text(
                      'لا توجد عمليات مقترحة للربط.',
                      textAlign: TextAlign.center,
                      style: AppTypography.caption(c.textSecondary),
                    ),
                  )
                else
                  for (final tx in suggestedTransactions.take(12))
                    _BillTransactionRow(tx: tx),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _showRecordPayment(
    BuildContext context,
    WidgetRef ref,
    BillEntity bill,
  ) async {
    final isInstallment = bill.type == BillType.installment;
    final period = _defaultPaymentPeriod(bill);
    final remainingCount = bill.remainingInstallments;
    final remainingAmount = remainingCount * bill.amount;
    final canPayFull = isInstallment && remainingCount > 1;

    final amountController =
        TextEditingController(text: bill.amount.toStringAsFixed(2));
    final noteController = TextEditingController();
    var payFull = false;
    var busy = false;
    String? errorMessage;
    final attempt = BillPaymentAttempt();

    final recorded = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => PopScope(
          canPop: !busy,
          child: AlertDialog(
            title: Text(isInstallment ? 'تسجيل دفع قسط' : 'تسجيل دفعة'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  payFull
                      ? 'سداد كل الأقساط المتبقية ($remainingCount) دفعة واحدة'
                      : period.installmentIndex == null
                          ? 'هذه الدفعة عن الفترة ${_shortDate(period.start)} - ${_shortDate(period.end)}'
                          : 'هذه الدفعة عن قسط رقم ${period.installmentIndex} للفترة ${_shortDate(period.start)} - ${_shortDate(period.end)}',
                  style: AppTypography.caption(context.colors.textSecondary),
                ),
                const SizedBox(height: AppSpacing.s3),
                TextField(
                  key: const ValueKey('bill-payment-amount'),
                  controller: amountController,
                  enabled: !busy && !payFull && attempt.payment == null,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: 'المبلغ',
                    suffixText: Currency.arabicLabel(bill.currency),
                  ),
                ),
                if (canPayFull) ...[
                  const SizedBox(height: AppSpacing.s2),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: payFull,
                    title: Text(
                      'سدّد المتبقي بالكامل (${Formatters.amount(remainingAmount)} ${Currency.arabicLabel(bill.currency)})',
                      style: AppTypography.caption(context.colors.textMain),
                    ),
                    onChanged: busy || attempt.payment != null
                        ? null
                        : (value) => setDialogState(() {
                              payFull = value ?? false;
                              amountController.text = payFull
                                  ? remainingAmount.toStringAsFixed(2)
                                  : bill.amount.toStringAsFixed(2);
                            }),
                  ),
                ],
                const SizedBox(height: AppSpacing.s3),
                TextField(
                  controller: noteController,
                  enabled: !busy && attempt.payment == null,
                  decoration: const InputDecoration(
                    labelText: 'ملاحظة اختيارية',
                  ),
                ),
                if (errorMessage != null) ...[
                  const SizedBox(height: AppSpacing.s3),
                  Text(
                    errorMessage!,
                    key: const ValueKey('bill-payment-error'),
                    style: AppTypography.caption(context.colors.danger),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: busy ? null : () => Navigator.of(context).pop(false),
                child: const Text('إلغاء'),
              ),
              FilledButton(
                key: const ValueKey('bill-payment-submit'),
                onPressed: busy
                    ? null
                    : () async {
                        final amount = payFull
                            ? remainingAmount
                            : _parseAmount(amountController.text);
                        if (amount == null || amount <= 0) return;
                        setDialogState(() {
                          busy = true;
                          errorMessage = null;
                        });
                        try {
                          await attempt.submit(
                            buildPayment: (requestId, paidAt) =>
                                BillPaymentEntity(
                              id: requestId,
                              billId: bill.id,
                              amount: amount,
                              currency: bill.currency,
                              periodStart: period.start,
                              periodEnd: period.end,
                              paidAt: paidAt,
                              installmentIndex: payFull
                                  ? bill.totalInstallments
                                  : period.installmentIndex,
                              note: noteController.text.trim().isEmpty
                                  ? null
                                  : noteController.text.trim(),
                            ),
                            createTransaction: (payment) =>
                                ref.read(saveManualTransactionUseCaseProvider)(
                              amount: payment.amount,
                              currency: payment.currency,
                              type: TransactionTypeEntity.payment,
                              occurredAt: payment.paidAt,
                              categoryKey: Categories.subscriptions.key,
                              merchant: bill.name,
                              note: payment.note ??
                                  (isInstallment
                                      ? 'قسط ${bill.name}'
                                      : 'اشتراك ${bill.name}'),
                              accountId: bill.accountId,
                            ),
                            recordPayment: (payment) => ref
                                .read(billRepositoryProvider)
                                .recordPayment(payment),
                          );
                          if (context.mounted) Navigator.of(context).pop(true);
                        } catch (error) {
                          if (!context.mounted) return;
                          setDialogState(() {
                            busy = false;
                            errorMessage = !attempt.hasTransaction
                                ? error is RepoException
                                    ? repoExceptionMessage(error)
                                    : 'تعذّر تسجيل الدفعة الآن. حاول مجددًا.'
                                : 'تم حفظ العملية، لكن تعذّر ربط الدفعة. أعد المحاولة ولن تتكرر العملية.';
                          });
                        }
                      },
                child: busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: Colors.white,
                        ),
                      )
                    : Text(errorMessage == null ? 'تسجيل' : 'إعادة المحاولة'),
              ),
            ],
          ),
        ),
      ),
    );
    amountController.dispose();
    noteController.dispose();
    if (recorded != true) return;
    ref.invalidate(billPaymentsProvider(bill.id));
    ref.invalidate(savedBillsProvider);
    ref.invalidate(billsViewProvider);
    ref.invalidate(dashboardDataProvider);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('تم تسجيل الدفعة وأضيفت للعمليات.')),
    );
  }

  Future<void> _confirmDelete(
      BuildContext context, WidgetRef ref, BillEntity bill) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('حذف الفاتورة؟'),
        content: Text('هيتم حذف "${bill.name}" من الاشتراكات والأقساط.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(billRepositoryProvider).delete(bill.id);
    } on RepoException catch (error) {
      if (!context.mounted) return;
      AppToast.showError(context, repoExceptionMessage(error));
      return;
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تعذّر حذف الفاتورة الآن.')),
      );
      return;
    }
    ref.invalidate(savedBillsProvider);
    ref.invalidate(subscriptionsProvider);
    ref.invalidate(billsViewProvider);
    ref.invalidate(dashboardDataProvider);
    if (!context.mounted) return;
    final navigator = Navigator.of(context);
    navigator.pop();
    AppToast.show(context, 'اتحذف ${bill.name}');
  }
}

class _SummaryTile extends StatelessWidget {
  const _SummaryTile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      children: [
        Text(label, style: AppTypography.caption(c.textSecondary)),
        const SizedBox(height: 3),
        Text(
          value,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTypography.subhead(c.textPrimary),
        ),
      ],
    );
  }
}

class _BillPaymentRow extends ConsumerWidget {
  const _BillPaymentRow({required this.payment, required this.bill});

  final BillPaymentEntity payment;
  final BillEntity bill;

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف الدفعة؟'),
        content: const Text('هيتحذف سجل الدفع اليدوي ده نهائياً.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('حذف', style: TextStyle(color: context.colors.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final transactionRepository = ref.read(transactionRepositoryProvider);
      final billRepository = ref.read(billRepositoryProvider);
      await ref.read(appDatabaseProvider).transaction(() async {
        if (payment.transactionId != null) {
          await transactionRepository.deleteTransaction(
            payment.transactionId!,
          );
        }
        await billRepository.deletePayment(payment.id);
      });
    } on RepoException catch (error) {
      if (!context.mounted) return;
      AppToast.showError(context, repoExceptionMessage(error));
      return;
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تعذّر حذف الدفعة الآن.')),
      );
      return;
    }
    ref.invalidate(billPaymentsProvider(bill.id));
    ref.invalidate(dashboardDataProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final isInstallment = bill.type == BillType.installment;
    final title = isInstallment && payment.installmentIndex != null
        ? 'قسط رقم ${payment.installmentIndex}'
        : 'دفعة ${bill.name}';
    final period =
        '${_shortDate(payment.periodStart)} - ${_shortDate(payment.periodEnd)}';
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.s2),
      padding: const EdgeInsets.all(AppSpacing.s3),
      decoration: BoxDecoration(
        color: c.success.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: c.success.withValues(alpha: 0.22)),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: c.success.withValues(alpha: 0.13),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(Icons.check_circle_outline, size: 18, color: c.success),
          ),
          const SizedBox(width: AppSpacing.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: AppTypography.caption(c.textPrimary)
                      .copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  period,
                  style: AppTypography.caption(c.textSecondary),
                ),
                if (payment.note?.trim().isNotEmpty == true) ...[
                  const SizedBox(height: 2),
                  Text(
                    payment.note!.trim(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.caption(c.textLight),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.s2),
          Text(
            '${Formatters.amount(payment.amount)} ${Currency.arabicLabel(payment.currency)}',
            style: AppTypography.caption(c.success).copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: AppSpacing.s2),
          GestureDetector(
            onTap: () => _delete(context, ref),
            child: Icon(Icons.delete_outline, size: 18, color: c.danger),
          ),
        ],
      ),
    );
  }
}

class _BillTransactionRow extends StatelessWidget {
  const _BillTransactionRow({required this.tx});

  final TransactionEntity tx;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final title = tx.rawMerchant?.trim().isNotEmpty == true
        ? tx.rawMerchant!.trim()
        : tx.note?.trim().isNotEmpty == true
            ? tx.note!.trim()
            : 'عملية';
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.md),
      onTap: () => TransactionDetailsScreen.showSheet(context, tx.id),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: c.cta.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(Icons.receipt_long_outlined, size: 17, color: c.cta),
            ),
            const SizedBox(width: AppSpacing.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.caption(c.textPrimary)
                        .copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    Formatters.fullDate(tx.occurredAt, context),
                    style: AppTypography.caption(c.textSecondary),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.s2),
            Text(
              '${Formatters.amount(tx.amount)} ${Currency.arabicLabel(tx.currency)}',
              style: AppTypography.caption(c.textPrimary)
                  .copyWith(fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}

Future<List<TransactionEntity>> _loadBillTransactions(
  WidgetRef ref,
  BillEntity bill,
) async {
  // B2-C — bounded recent-expenses page (account + kind pushed to SQL) instead
  // of the whole ledger; `_matchesBill` re-applies the exact confirmed/currency
  // predicate. A bill's payment history within the recent page is shown (a
  // subscription's history rarely exceeds this bound).
  final all = await ref.read(transactionRepositoryProvider).getTransactionPage(
        limit: 500,
        filter: TransactionPageFilter(
          accountId: bill.accountId,
          kind: TransactionPageKind.expenses,
        ),
      );
  final transactions = all.where((tx) => _matchesBill(tx, bill)).toList();
  transactions.sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
  return transactions;
}

bool _matchesBill(TransactionEntity tx, BillEntity bill) {
  if (tx.status != TransactionStatus.confirmed) return false;
  final isExpense = tx.type == TransactionTypeEntity.payment ||
      tx.type == TransactionTypeEntity.withdrawal;
  if (!isExpense) return false;
  if (bill.accountId != null && tx.accountId != bill.accountId) return false;
  if (bill.accountId == null &&
      tx.accountId == null &&
      tx.currency.toUpperCase() != bill.currency.toUpperCase()) {
    return false;
  }
  if (bill.merchantId != null && tx.merchantId == bill.merchantId) return true;
  final merchant = _searchKey(tx.rawMerchant ?? '');
  final name = _searchKey(bill.name);
  final lender = _searchKey(bill.lenderName ?? '');
  if (merchant.isEmpty) return false;
  return merchant.contains(name) ||
      name.contains(merchant) ||
      (lender.isNotEmpty &&
          (merchant.contains(lender) || lender.contains(merchant)));
}

String _searchKey(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'[\s\-_.,،]+'), '');

class _PaymentPeriod {
  const _PaymentPeriod({
    required this.start,
    required this.end,
    this.installmentIndex,
  });

  final DateTime start;
  final DateTime end;
  final int? installmentIndex;
}

_PaymentPeriod _defaultPaymentPeriod(BillEntity bill) {
  final now = DateTime.now();
  final local = DateTime(now.year, now.month, now.day);
  final DateTime start;
  final DateTime end;
  switch (bill.frequency) {
    case BillFrequency.weekly:
      start = local.subtract(Duration(days: local.weekday - 1));
      end = start.add(const Duration(days: 6));
    case BillFrequency.monthly:
      start = DateTime(local.year, local.month);
      end = DateTime(local.year, local.month + 1)
          .subtract(const Duration(days: 1));
    case BillFrequency.yearly:
      start = DateTime(local.year);
      end = DateTime(local.year + 1).subtract(const Duration(days: 1));
    case BillFrequency.custom:
      start = local;
      end = local.add(Duration(days: (bill.customIntervalDays ?? 1) - 1));
  }
  final nextInstallment = bill.type == BillType.installment
      ? ((bill.paidCount ?? 0) + 1)
          .clamp(1, bill.totalInstallments ?? 9999)
          .toInt()
      : null;
  return _PaymentPeriod(
    start: start,
    end: end,
    installmentIndex: nextInstallment,
  );
}

double? _parseAmount(String value) {
  final normalized = value
      .replaceAll('٫', '.')
      .replaceAll(',', '.')
      .replaceAll(RegExp(r'[^0-9.]'), '');
  if (normalized.isEmpty) return null;
  return double.tryParse(normalized);
}

String _shortDate(DateTime value) {
  final local = value.toLocal();
  return '${local.day}/${local.month}/${local.year}';
}

String _frequencyLabel(BillFrequency frequency) => switch (frequency) {
      BillFrequency.weekly => 'أسبوعي',
      BillFrequency.monthly => 'شهري',
      BillFrequency.yearly => 'سنوي',
      BillFrequency.custom => 'مخصص',
    };

String _statusLabel(BillEntity bill) {
  if (bill.type == BillType.installment) return 'قسط جاري';
  return switch (bill.status) {
    BillStatus.active => 'نشط',
    BillStatus.paused => 'متوقف',
    BillStatus.cancelled => 'ملغي',
  };
}

Color _statusColor(BuildContext context, BillEntity bill) {
  final c = context.colors;
  if (bill.type == BillType.installment) return c.primary;
  return switch (bill.status) {
    BillStatus.active => c.success,
    BillStatus.paused => c.accent,
    BillStatus.cancelled => c.textMuted,
  };
}

String _dueLabel(DateTime dueDate) {
  final daysLeft = dueDate.difference(DateTime.now()).inDays;
  if (daysLeft < 0) return 'متأخر ${daysLeft.abs()} يوم';
  if (daysLeft == 0) return 'مستحق اليوم';
  return 'بعد $daysLeft يوم';
}
