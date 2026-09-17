import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/utils/async_reload_safe.dart';
import '../../core/utils/l10n_ext.dart';

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
import '../../domain/finance/money.dart';
import '../../domain/finance/money_input.dart';
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
import '../../core/utils/app_lucide_icons.dart';
import '../common/repo_error_messages.dart';

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
    final currLabel = Currency.label(context, currentBill.currency);
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
      subtitle: isInstallment ? context.l10n.bfInstalment : context.l10n.bfSubscription,
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
              manualPaidMoney: currentBill.safeManualPaidMoney,
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
                          Text(_statusLabel(context, currentBill),
                              style: AppTypography.bodyStrong(
                                  _statusColor(context, currentBill))),
                          const SizedBox(height: 2),
                          Text(
                            [
                              _frequencyLabel(context, currentBill.frequency),
                              _dueLabel(context, currentBill.nextDueDate),
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
                          label: isInstallment ? context.l10n.bdsInstalmentValue : context.l10n.bdgAmount,
                          value:
                              '${Formatters.amount(currentBill.amount)} $currLabel',
                        ),
                      ),
                      Container(width: 1, height: 38, color: c.border),
                      Expanded(
                        child: _SummaryTile(
                          label: context.l10n.bdsTotalPaid,
                          value: '${Formatters.amount(totalPaid)} $currLabel',
                        ),
                      ),
                      Container(width: 1, height: 38, color: c.border),
                      Expanded(
                        child: _SummaryTile(
                          label: context.l10n.bdsRecordedPayments,
                          value: '${payments.length}',
                        ),
                      ),
                    ],
                  ),
                ),
                if (legacyManualPaid > 0) ...[
                  const SizedBox(height: AppSpacing.s2),
                  Text(
                    context.l10n.bdsIncludesLegacyManual(
                  Formatters.amount(legacyManualPaid), currLabel),
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
                            label: context.l10n.bdsPaid,
                            value:
                                context.l10n.homeNofM(currentBill.paidCount ?? 0,
                  currentBill.totalInstallments ?? 0),
                          ),
                        ),
                        Container(width: 1, height: 38, color: c.border),
                        Expanded(
                          child: _SummaryTile(
                            label: context.l10n.bdsRemaining,
                            value: '${currentBill.remainingInstallments}',
                          ),
                        ),
                        Container(width: 1, height: 38, color: c.border),
                        Expanded(
                          child: _SummaryTile(
                            label: context.l10n.bdsProgress,
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
                  icon: const Icon(AppLucideIcons.creditCard),
                  label: Text(isInstallment ? context.l10n.bdsRecordInstalmentPayment : context.l10n.bdsRecordPayment),
                ),
                const SizedBox(height: AppSpacing.s3),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () =>
                            BillFormSheet.show(context, bill: currentBill),
                        icon: const Icon(AppLucideIcons.pencil),
                        label: Text(context.l10n.cardEdit),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.s3),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () =>
                            _confirmDelete(context, ref, currentBill),
                        icon: const Icon(AppLucideIcons.trash2),
                        label: Text(context.l10n.setDelete),
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
                Text(context.l10n.bdsPaymentHistory,
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
                          ? context.l10n.bdsNoManualInstalmentPayments
                          : context.l10n.bdsNoManualSubPayments,
                      textAlign: TextAlign.center,
                      style: AppTypography.caption(c.textSecondary),
                    ),
                  )
                else
                  for (final payment in payments)
                    _BillPaymentRow(payment: payment, bill: currentBill),
                const SizedBox(height: AppSpacing.s5),
                Text(context.l10n.bdsSuggestedToLink,
                    style: AppTypography.bodyStrong(c.textPrimary)),
                const SizedBox(height: 2),
                Text(
                  context.l10n.bdsNameMatchNote,
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
                      context.l10n.bdsNoSuggestions,
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
    final remainingAmountMoney = bill.amountMoney * remainingCount;
    final remainingAmount = remainingAmountMoney.toDouble();
    final canPayFull = isInstallment && remainingCount > 1;

    // CANONICAL seed: this text is parsed back into Money when the payment is
    // recorded, so truncating here shifted the recorded payment (KWD 12.345 →
    // 12.350) on every single payment.
    final amountController =
        TextEditingController(text: bill.amountMoney.toDecimalString());
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
            title: Text(isInstallment ? context.l10n.bdsRecordInstalmentPayment : context.l10n.bdsRecordPayment),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  payFull
                      ? context.l10n.bdsPayAllRemaining(remainingCount)
                      : period.installmentIndex == null
                          ? context.l10n.bdsPaymentForPeriod(
                        _shortDate(period.start), _shortDate(period.end))
                          : context.l10n.bdsPaymentForInstalment(period.installmentIndex ?? 0,
                        _shortDate(period.start), _shortDate(period.end)),
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
                    labelText: context.l10n.bdgAmount,
                    suffixText: Currency.label(context, bill.currency),
                  ),
                ),
                if (canPayFull) ...[
                  const SizedBox(height: AppSpacing.s2),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: payFull,
                    title: Text(
                      context.l10n.bdsPayRemainingInFull(Formatters.amount(remainingAmount),
            Currency.label(context, bill.currency)),
                      style: AppTypography.caption(context.colors.textMain),
                    ),
                    onChanged: busy || attempt.payment != null
                        ? null
                        : (value) => setDialogState(() {
                              payFull = value ?? false;
                              // Exact: `remainingAmountMoney` is already
                              // Money*int. Rounding it here made "pay all
                              // remaining" overshoot the real debt.
                              amountController.text = payFull
                                  ? remainingAmountMoney.toDecimalString()
                                  : bill.amountMoney.toDecimalString();
                            }),
                  ),
                ],
                const SizedBox(height: AppSpacing.s3),
                TextField(
                  controller: noteController,
                  enabled: !busy && attempt.payment == null,
                  decoration: InputDecoration(
                    labelText: context.l10n.bdsOptionalNote,
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
                child: Text(context.l10n.commonCancel),
              ),
              FilledButton(
                key: const ValueKey('bill-payment-submit'),
                onPressed: busy
                    ? null
                    : () async {
                        final Money? amountMoney;
                        try {
                          amountMoney = payFull
                              ? remainingAmountMoney
                              : _parseAmount(
                                  amountController.text,
                                  bill.currency,
                                );
                        } on Exception {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(context.l10n.bfInvalidAmount)),
                          );
                          return;
                        }
                        if (amountMoney == null ||
                            amountMoney.minorUnits <= 0) {
                          return;
                        }
                        final paymentAmountMoney = amountMoney;
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
                              amountMoney: paymentAmountMoney,
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
                              amount: payment.amountMoney,
                              currency: payment.currency,
                              type: TransactionTypeEntity.payment,
                              occurredAt: payment.paidAt,
                              categoryKey: Categories.subscriptions.key,
                              merchant: bill.name,
                              note: payment.note ??
                                  (isInstallment
                                      ? context.l10n.bdsInstalmentNamed(bill.name)
                                      : context.l10n.bdsSubscriptionNamed(bill.name)),
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
                                    ? repoErrorMessage(context, error)
                                    : context.l10n.bdsRecordFailed
                                : context.l10n.bdsSavedButNotLinked;
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
                    : Text(errorMessage == null ? context.l10n.bdsRecord : context.l10n.annRetry),
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
      SnackBar(content: Text(context.l10n.bdsPaymentRecorded)),
    );
  }

  Future<void> _confirmDelete(
      BuildContext context, WidgetRef ref, BillEntity bill) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.bdsDeleteBillTitle),
        content: Text(context.l10n.bdsDeleteBody(bill.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.l10n.setDelete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(billRepositoryProvider).delete(bill.id);
    } on RepoException catch (error) {
      if (!context.mounted) return;
      AppToast.showError(context, repoErrorMessage(context, error));
      return;
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.bdsDeleteBillFailed)),
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
    AppToast.show(context, context.l10n.bdsDeleted(bill.name));
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
        title: Text(context.l10n.bdsDeletePaymentTitle),
        content: Text(context.l10n.bdsDeletePaymentBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(context.l10n.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(context.l10n.setDelete, style: TextStyle(color: context.colors.danger)),
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
      AppToast.showError(context, repoErrorMessage(context, error));
      return;
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.bdsDeletePaymentFailed)),
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
        ? context.l10n.bdsInstalmentNumber(payment.installmentIndex ?? 0)
        : context.l10n.bdsPaymentNamed(bill.name);
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
            child: Icon(AppLucideIcons.checkCircle, size: 18, color: c.success),
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
            '${Formatters.amount(payment.amount)} ${Currency.label(context, payment.currency)}',
            style: AppTypography.caption(c.success).copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: AppSpacing.s2),
          GestureDetector(
            onTap: () => _delete(context, ref),
            child: Icon(AppLucideIcons.trash2, size: 18, color: c.danger),
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
            : context.l10n.txnTransactionWord;
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
              child: Icon(AppLucideIcons.receipt, size: 17, color: c.cta),
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
              '${Formatters.amount(tx.amount)} ${Currency.label(context, tx.currency)}',
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

Money? _parseAmount(String value, String currency) {
  if (value.trim().isEmpty) return null;
  return parseLocalizedMoney(value, currency);
}

String _shortDate(DateTime value) {
  final local = value.toLocal();
  return '${local.day}/${local.month}/${local.year}';
}

String _frequencyLabel(BuildContext context, BillFrequency frequency) =>
    switch (frequency) {
      BillFrequency.weekly => context.l10n.txnCycleWeekly,
      BillFrequency.monthly => context.l10n.txnCycleMonthly,
      BillFrequency.yearly => context.l10n.txnCycleYearly,
      BillFrequency.custom => context.l10n.txnRangeCustom,
    };

String _statusLabel(BuildContext context, BillEntity bill) {
  if (bill.type == BillType.installment) return context.l10n.txnRunningInst;
  return switch (bill.status) {
    BillStatus.active => context.l10n.txnActive,
    BillStatus.paused => context.l10n.txnPaused,
    BillStatus.cancelled => context.l10n.txnCancelled,
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

String _dueLabel(BuildContext context, DateTime dueDate) {
  final daysLeft = dueDate.difference(DateTime.now()).inDays;
  if (daysLeft < 0) return context.l10n.txnOverdueDays(daysLeft.abs());
  if (daysLeft == 0) return context.l10n.txnDueToday;
  return context.l10n.txnInDays(daysLeft);
}
