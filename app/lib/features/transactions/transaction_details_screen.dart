import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/utils/l10n_ext.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/navy_sheet_theme.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/transaction_entity.dart';
import '../../domain/finance/money.dart';
import '../../domain/finance/money_input.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../cards/brand_mark.dart';
import '../cards/cards_providers.dart';
import '../../domain/entities/card_entity.dart';
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
import '../../core/theme/widgets/app_toast.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../common/repo_error_messages.dart';

class TransactionDetailsScreen extends ConsumerWidget {
  const TransactionDetailsScreen({super.key, required this.transactionId});

  final String transactionId;

  // Was a `static const` map. Localized copy cannot be const, and a lookup
  // table that is built once at class-load would freeze whichever language
  // happened to be active then.
  static String _typeLabel(BuildContext context, TransactionTypeEntity type) =>
      switch (type) {
        TransactionTypeEntity.payment => context.l10n.txdTypePurchase,
        TransactionTypeEntity.withdrawal => context.l10n.txdTypeCashWithdrawal,
        TransactionTypeEntity.transfer => context.l10n.txdTypeTransfer,
        TransactionTypeEntity.refund => context.l10n.txdTypeRefund,
        TransactionTypeEntity.income => context.l10n.txnKindIncome,
        TransactionTypeEntity.unknown => context.l10n.txdTypeUnknown,
      };

  static String _sourceLabel(
          BuildContext context, TransactionSourceEntity source) =>
      switch (source) {
        TransactionSourceEntity.bank => context.l10n.accTypeBank,
        TransactionSourceEntity.card => context.l10n.txdSourceCard,
        TransactionSourceEntity.wallet => context.l10n.accTypeWallet,
        TransactionSourceEntity.unknown => context.l10n.txdTypeUnknown,
        TransactionSourceEntity.aiParsed => context.l10n.txdSourceAi,
        TransactionSourceEntity.imported => context.l10n.txdSourceImport,
      };

  static Future<void> showSheet(BuildContext context, String transactionId) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => navySheetTheme(
          _TransactionDetailsSheet(transactionId: transactionId)),
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
      skipLoadingOnReload: true,
      loading: () => _buildScaffold(
          context, c, const Center(child: CircularProgressIndicator())),
      error: (e, _) =>
          _buildScaffold(context, c, Center(child: Text(context.l10n.txnError))),
      data: (tx) {
        if (tx == null) {
          return _buildScaffold(
              context, c, Center(child: Text(context.l10n.txdNotFound)));
        }

        final category = catalog?.byId(tx.categoryId);
        final isDebit = transactionIsDebit(tx);
        final amountColor = isDebit ? c.danger : c.success;
        final merchantTitle = tx.rawMerchant?.trim().isNotEmpty == true
            ? tx.rawMerchant!.trim()
            : category?.name ?? context.l10n.txnTransactionWord;
        final statusColor = switch (tx.status) {
          TransactionStatus.confirmed => c.success,
          TransactionStatus.pending => c.accent,
          TransactionStatus.ignored => c.textMuted,
        };
        final statusLabel = switch (tx.status) {
          TransactionStatus.confirmed => context.l10n.txdConfirmed,
          TransactionStatus.pending => context.l10n.txdNeedsReview,
          TransactionStatus.ignored => context.l10n.txdIgnored,
        };
        final editButton = IconButton(
          tooltip: context.l10n.txnEditTx,
          onPressed: () => ManualTransactionSheet.show(
            context,
            transaction: tx,
          ),
          icon: Icon(AppLucideIcons.pencil, color: c.textPrimary),
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
              // هيرو متمركز بدون كارت: التايل، اسم التاجر، وحالة العملية،
              // والمبلغ هو أكبر عنصر في الشيت.
              Center(
                child: Column(
                  children: [
                    (tx.rawMerchant != null &&
                            BrandMark.hasBrand(tx.rawMerchant!))
                        ? AppAvatar.brand(
                            name: tx.rawMerchant!, size: AppSpacing.avatarLg)
                        : AppAvatar.category(
                            category: category, size: AppSpacing.avatarLg),
                    const SizedBox(height: AppSpacing.s3),
                    Text(
                      merchantTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: AppTypography.cardTitle(c.textPrimary),
                    ),
                    const SizedBox(height: AppSpacing.s2),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: AnimatedAmountText(
                        amount:
                            (tx.pricingState == TransactionPricingState.awaitingFx)
                                ? tx.foreignAmount!
                                : tx.amount,
                        color: amountColor,
                        suffix:
                            (tx.pricingState == TransactionPricingState.awaitingFx)
                                ? ' ${tx.foreignCurrency}'
                                : ' ${Currency.label(context, tx.currency)}',
                        style: AppTypography.amountHero(amountColor),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.s2),
                    Text(
                      '${Formatters.dateWithWeekday(tx.occurredAt, context)} · ${Formatters.time(tx.occurredAt)}',
                      textAlign: TextAlign.center,
                      style: AppTypography.caption(c.textSecondary),
                    ),
                    const SizedBox(height: AppSpacing.s3),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 5),
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                      ),
                      child: Text(
                        statusLabel,
                        style: AppTypography.caption(statusColor)
                            .copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    if (tx.pricingState == TransactionPricingState.awaitingFx &&
                        tx.foreignCurrency != null) ...[
                      const SizedBox(height: AppSpacing.s3),
                      AppButton(
                        label:
                            context.l10n.txdAddValueIn(Currency.label(context, tx.currency)),
                        onPressed: () => _promptForPrice(context, ref, tx),
                        isPrimary: true,
                        height: 42,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.s5),
              // صف إجراءات: تعديل / تغيير التصنيف — بدل ما يبقوا مبعترين
              // جوه صفوف التفاصيل.
              Row(
                children: [
                  Expanded(
                    child: _QuickAction(
                      icon: AppLucideIcons.pencil,
                      label: context.l10n.cardEdit,
                      onTap: () =>
                          ManualTransactionSheet.show(context, transaction: tx),
                    ),
                  ),
                  if (catalog != null) ...[
                    const SizedBox(width: AppSpacing.s3),
                    Expanded(
                      child: _QuickAction(
                        icon: AppLucideIcons.shapes,
                        label: context.l10n.txnChangeCategory,
                        onTap: () =>
                            showChangeCategorySheet(context, tx, catalog),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: AppSpacing.s4),

              // Details Card
              AppCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    _buildDetailRow(
                      context,
                      context.l10n.txnCategory,
                      category?.name ?? context.l10n.txdUncategorised,
                    ),
                    _divider(c),
                    _buildDetailRow(
                      context,
                      context.l10n.txdType,
                      TransactionDetailsScreen._typeLabel(context, tx.type),
                    ),
                    _divider(c),
                    _buildDetailRow(
                      context,
                      context.l10n.txdSource,
                      TransactionDetailsScreen._sourceLabel(context, tx.source),
                    ),
                    // UX-034 — the account and the card were compressed into
                    // one «المصدر» line («بطاقة · 1234») with the account
                    // missing entirely. The finding is that linking, unlinking
                    // and reassigning a card is hard to understand, and its
                    // binding constraint is that the UI must "never hide
                    // whether changing a card also changes its account".
                    //
                    // They are separate facts, so they are separate rows. The
                    // account is stated even when there is no card, because a
                    // transaction always belongs to one.
                    _divider(c),
                    _buildDetailRow(
                      context,
                      context.l10n.commonAccountDefinite,
                      _accountName(ref, tx.accountId),
                    ),
                    _divider(c),
                    _buildDetailRow(
                      context,
                      context.l10n.txdCard,
                      tx.cardLast4 == null
                          ? context.l10n.txdNoCard
                          : '•••• ${tx.cardLast4}',
                      trailing: TextButton(
                        onPressed: () => _editCard(context, ref, tx),
                        style: TextButton.styleFrom(
                          padding: EdgeInsets.zero,
                          minimumSize: const Size(0, 0),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text(context.l10n.txdChange,
                            style: AppTypography.footnote(c.cta)),
                      ),
                    ),
                    _divider(c),
                    _buildDetailRow(
                      context,
                      context.l10n.dtxCurrency,
                      Currency.label(context, tx.currency),
                    ),
                    if (tx.foreignAmount != null &&
                        tx.foreignCurrency != null) ...[
                      _divider(c),
                      _buildDetailRow(
                        context,
                        context.l10n.txdOriginalCurrency,
                        '${Formatters.amount(tx.foreignAmount!)} ${tx.foreignCurrency!}',
                      ),
                    ],
                    if (tx.balanceAfter != null) ...[
                      _divider(c),
                      _buildDetailRow(
                        context,
                        context.l10n.txdBalanceAfter,
                        '${Formatters.amount(tx.balanceAfter!)} ${tx.currency}',
                      ),
                    ],
                    if (tx.note != null && tx.note!.isNotEmpty) ...[
                      _divider(c),
                      _buildDetailRow(
                        context,
                        context.l10n.txdNote,
                        tx.note!,
                      ),
                    ],
                    if (tx.status == TransactionStatus.pending) ...[
                      _divider(c),
                      _buildDetailRow(
                        context,
                        context.l10n.txdStatus,
                        _pendingLabel(context, tx.createdAt),
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
                  title: Text(context.l10n.txdOriginalText,
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
                    icon: const Icon(AppLucideIcons.badgeCheck),
                    label: Text(
                      tx.status == TransactionStatus.ignored
                          ? context.l10n.txdConfirmIgnored
                          : context.l10n.txdConfirmTx,
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.s2),
              ],
              TextButton.icon(
                onPressed: () => _confirmDelete(context, ref, tx.id),
                icon: Icon(AppLucideIcons.trash2, color: c.danger),
                label: Text(context.l10n.txdDeleteTx,
                    style: AppTypography.bodyStrong(c.danger)),
              ),
            ],
          ),
        );

        return _buildScaffold(context, c, body,
            title: context.l10n.txdTitle, trailing: editButton);
      },
    );
  }

  /// UX-034 — the account a transaction belongs to, by name.
  ///
  /// Falls back to a plain «—» rather than the raw id: a UUID on a detail sheet
  /// answers nothing, and an unresolvable account is a data question rather
  /// than something to render at the user.
  String _accountName(WidgetRef ref, String? accountId) {
    if (accountId == null) return '—';
    final accounts = ref.watch(accountsProvider).valueOrNull ?? const [];
    for (final a in accounts) {
      if (a.id == accountId) return a.name;
    }
    return '—';
  }

  /// UX-034 — reassign or detach the transaction's card.
  ///
  /// The repository's `updateCard` writes `card_last4` and nothing else, so the
  /// account genuinely does not move with it. That is the finding's binding
  /// constraint — *"never hide whether changing a card also changes its
  /// account"* — and since the answer is "it doesn't", the sheet says so
  /// outright instead of leaving the user to infer it.
  ///
  /// Only cards belonging to the transaction's OWN account are offered.
  /// Offering every card in the app would invite a pairing that contradicts the
  /// account shown one row above.
  Future<void> _editCard(
    BuildContext context,
    WidgetRef ref,
    TransactionEntity tx,
  ) async {
    final cards = (ref.read(allCardsProvider).valueOrNull ?? const <CardEntity>[])
        .where((card) => card.accountId == tx.accountId)
        .toList(growable: false);

    final choice = await showModalBottomSheet<String?>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => navySheetTheme(Builder(
        builder: (sheetContext) {
          final sc = sheetContext.colors;
          return AppSheetScaffold(
            title: context.l10n.txdCardSheetTitle,
            subtitle: context.l10n.txdCardSheetNote,
            scrollable: true,
            body: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final card in cards)
                    ListTile(
                      leading: Icon(AppLucideIcons.creditCard, color: sc.cta),
                      title: Text('•••• ${card.last4}',
                          style: AppTypography.subhead(sc.textMain)),
                      trailing: card.last4 == tx.cardLast4
                          ? Icon(AppLucideIcons.check, color: sc.success)
                          : null,
                      onTap: () =>
                          Navigator.of(sheetContext).pop(card.last4),
                    ),
                  if (cards.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          vertical: AppSpacing.s3),
                      child: Text(
                        context.l10n.txdNoCardsOnAccount,
                        style: AppTypography.caption(sc.textSecondary),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  const SizedBox(height: AppSpacing.s2),
                  ListTile(
                    leading: Icon(AppLucideIcons.unlink, color: sc.textLight),
                    title: Text(context.l10n.txdNoCard,
                        style: AppTypography.subhead(sc.textMain)),
                    subtitle: Text(
                      context.l10n.txdStaysInAccount,
                      style: AppTypography.caption(sc.textSecondary),
                    ),
                    trailing: tx.cardLast4 == null
                        ? Icon(AppLucideIcons.check, color: sc.success)
                        : null,
                    // Sentinel rather than null: null is also what a dismissed
                    // sheet returns, and "the user backed out" must not be
                    // read as "the user chose to detach the card".
                    onTap: () => Navigator.of(sheetContext).pop('__none__'),
                  ),
                ],
              ),
            ),
          );
        },
      )),
    );

    if (choice == null || !context.mounted) return;
    final next = choice == '__none__' ? null : choice;
    if (next == tx.cardLast4) return;

    await ref
        .read(transactionRepositoryProvider)
        .updateCard(transactionId: tx.id, cardLast4: next);
    ref.invalidate(transactionByIdProvider(tx.id));
    refreshTransactions(ref);
    ref.invalidate(dashboardDataProvider);
    ref.invalidate(cardSummariesProvider);
    ref.invalidate(allCardsProvider);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(next == null
            ? context.l10n.txdCardRemoved
            : context.l10n.txdLinkedToCard(next)),
      ),
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
      SnackBar(content: Text(context.l10n.txdConfirmedToast)),
    );
  }

  Future<void> _confirmDelete(
      BuildContext context, WidgetRef ref, String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.l10n.txdDeleteTitle),
        content: Text(context.l10n.txdDeleteBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(context.l10n.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(context.l10n.setDelete, style: TextStyle(color: ctx.colors.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    late final List<String> affectedBillIds;
    try {
      final transactionRepository = ref.read(transactionRepositoryProvider);
      final billRepository = ref.read(billRepositoryProvider);
      affectedBillIds = await ref.read(appDatabaseProvider).transaction(
        () async {
          await transactionRepository.deleteTransaction(id);
          return billRepository.deletePaymentForTransaction(id);
        },
      );
    } on RepoException catch (e) {
      if (!context.mounted) return;
      AppToast.show(context, repoErrorMessage(context, e));
      return;
    }
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
        title: title ?? context.l10n.txdTitle,
        trailing: trailing,
        leading: IconButton(
          tooltip: context.l10n.annClose,
          onPressed: () => Navigator.of(context).pop(),
          icon: Icon(AppLucideIcons.x, color: c.textSecondary),
        ),
        scrollable: true,
        body: body,
      );
    } else {
      return AppScreenScaffold(
        header: AppHeader(
          title: title ?? context.l10n.txdTitle,
          action: trailing,
          showBack: true,
        ),
        body: SingleChildScrollView(child: body),
      );
    }
  }

  String _pendingLabel(BuildContext context, DateTime createdAt) {
    final days = DateTime.now().difference(createdAt).inDays;
    if (days == 0) return context.l10n.txdPendingToday;
    return context.l10n.txdPendingDays(days);
  }

  /// Prompts for the home-currency value of a foreign spend that is still
  /// "awaiting pricing" (amount 0), then stores it so it counts in totals.
  Future<void> _promptForPrice(
    BuildContext context,
    WidgetRef ref,
    TransactionEntity tx,
  ) async {
    final controller = TextEditingController();
    final value = await showDialog<Money>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.l10n.txdValueIn(Currency.label(context, tx.currency))),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: context.l10n.txdAmountIn(Currency.label(context, tx.currency)),
            hintText: '${Formatters.amount(tx.foreignAmount ?? 0)} '
                '${tx.foreignCurrency ?? ''}',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(context.l10n.commonCancel),
          ),
          TextButton(
            onPressed: () {
              try {
                Navigator.of(ctx)
                    .pop(parseLocalizedMoney(controller.text, tx.currency));
              } on Exception {
                Navigator.of(ctx).pop();
              }
            },
            child: Text(context.l10n.txdSave),
          ),
        ],
      ),
    );
    // Do NOT dispose controller here – the dialog's exit animation may still
    // reference it. It will be GC'd when the method scope ends.
    if (value == null || value.minorUnits <= 0) return;
    try {
      await ref
          .read(transactionRepositoryProvider)
          .updateAmount(transactionId: tx.id, amount: value);
    } on RepoException catch (e) {
      if (!context.mounted) return;
      AppToast.show(context, repoErrorMessage(context, e));
      return;
    }
    ref.invalidate(transactionByIdProvider(tx.id));
    refreshTransactions(ref);
    ref.invalidate(dashboardDataProvider);
  }

  /// صف تفاصيل: الاسم على جنب والقيمة على الجنب التاني — أهدأ من عمود
  /// بعرض ثابت، والقيم الطويلة بتاخد المساحة اللي فاضلة.
  Widget _buildDetailRow(BuildContext context, String label, String value,
      {Widget? trailing, bool isPending = false}) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s4, vertical: AppSpacing.s3),
      child: Row(
        children: [
          Text(
            label,
            style: AppTypography.callout(c.textSecondary),
          ),
          const SizedBox(width: AppSpacing.s3),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style:
                  AppTypography.subhead(isPending ? c.accent : c.textPrimary),
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: AppSpacing.s2),
            trailing,
          ],
        ],
      ),
    );
  }

  Widget _divider(AppColors c) {
    return Divider(
      height: 1,
      thickness: 1,
      color: c.border.withValues(alpha: 0.5),
      indent: AppSpacing.s4,
      endIndent: AppSpacing.s4,
    );
  }
}

/// زرار إجراء مربّع صغير في صف الإجراءات فوق التفاصيل.
class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: c.surfaceElevated,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Container(
          height: 46,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: c.divider),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: c.textPrimary),
              const SizedBox(width: AppSpacing.s2),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.subhead(c.textPrimary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
