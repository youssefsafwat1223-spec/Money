import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/currency.dart';
import '../../domain/entities/account_entity.dart';
import '../../domain/entities/card_entity.dart';
import '../cards/bank_mark.dart';
import '../cards/card_form_sheet.dart';
import '../cards/card_network_badge.dart';
import '../cards/cards_providers.dart';
import '../common/app_header.dart';
import '../common/category_catalog.dart';
import '../common/widgets.dart';
import 'account_form_sheet.dart';
import 'accounts_providers.dart';

/// تفاصيل حساب: بطاقاته المُكتشفة بثقة داخله + آخر عملياته. المسار `/account/:id`.
class AccountDetailScreen extends ConsumerWidget {
  const AccountDetailScreen({super.key, required this.accountId});

  final String accountId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final accountsAsync = ref.watch(accountsProvider);
    final account = accountsAsync.valueOrNull
        ?.where((a) => a.id == accountId)
        .cast<AccountEntity?>()
        .firstWhere((a) => true, orElse: () => null);

    if (account == null) {
      return Scaffold(
        backgroundColor: c.bg,
        appBar: const AppHeader(title: 'الحساب'),
        body: Center(
          child: accountsAsync.isLoading
              ? const CircularProgressIndicator()
              : Text('الحساب غير موجود', style: AppTypography.body(c.textMain)),
        ),
      );
    }

    final cards =
        ref.watch(accountCardsProvider(accountId)).valueOrNull ?? const [];
    final txAsync = ref.watch(accountRecentTransactionsProvider(accountId));
    final catalog = ref.watch(categoryCatalogProvider).valueOrNull;

    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppHeader(
        title: account.name,
        trailing: IconButton(
          tooltip: 'تعديل',
          icon: const Icon(Icons.edit_outlined),
          onPressed: () => showAccountForm(context, ref, account: account),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter, AppSpacing.s2, AppSpacing.gutter, 120),
        children: [
          _AccountHeaderCard(account: account),
          const SizedBox(height: AppSpacing.s4),
          Row(
            children: [
              Text('البطاقات', style: AppTypography.sectionTitle(c.textMain)),
              const Spacer(),
              TextButton.icon(
                onPressed: () =>
                    showCardForm(context, ref, accountId: accountId),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('إضافة بطاقة'),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s2),
          if (cards.isEmpty)
            Text(
                'لا توجد بطاقات بعد — تظهر تلقائيًا من رسائلك أو أضفها يدويًا.',
                style: AppTypography.caption(c.textLight))
          else
            for (final card in cards) ...[
              _ManagedCardRow(accountId: accountId, card: card),
              const SizedBox(height: AppSpacing.s2),
            ],
          const SizedBox(height: AppSpacing.s4),
          Text('آخر العمليات', style: AppTypography.sectionTitle(c.textMain)),
          const SizedBox(height: AppSpacing.s2),
          txAsync.when(
            skipLoadingOnReload: true,
            loading: () => const Center(
                child: Padding(
                    padding: EdgeInsets.all(AppSpacing.cardPadding),
                    child: CircularProgressIndicator())),
            error: (e, _) => const Text('حدث خطأ'),
            data: (txns) {
              if (txns.isEmpty) {
                return Text('لا توجد عمليات بعد',
                    style: AppTypography.callout(c.textLight));
              }
              return Column(
                children: [
                  for (final tx in txns)
                    TransactionRow(
                      transaction: tx,
                      category: catalog?.byId(tx.categoryId),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _AccountHeaderCard extends StatelessWidget {
  const _AccountHeaderCard({required this.account});

  final AccountEntity account;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s4),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          BankMark(
            accountName: account.name,
            accountType: account.type,
            size: 46,
          ),
          const SizedBox(width: AppSpacing.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(account.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.bodyStrong(c.textMain)),
                const SizedBox(height: 2),
                Text(
                  '${accountTypeLabel(account.type)} · ${Currency.arabicLabel(account.currency)} (${account.currency})',
                  style: AppTypography.caption(c.textLight),
                ),
              ],
            ),
          ),
          if (account.isDefault)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: c.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
              child: Text('افتراضي',
                  style: AppTypography.caption(c.primary)
                      .copyWith(fontWeight: FontWeight.w700)),
            ),
        ],
      ),
    );
  }
}

/// صف بطاقة مُدارة داخل الحساب: يفتح التفاصيل بالنقر، ويعدّل عبر أيقونة القلم.
class _ManagedCardRow extends ConsumerWidget {
  const _ManagedCardRow({required this.accountId, required this.card});

  final String accountId;
  final CardEntity card;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final title =
        card.nickname?.isNotEmpty == true ? card.nickname! : card.network.label;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.card),
      onTap: () => context.push('/card/${card.last4}'),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.s3),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: c.border),
        ),
        child: Row(
          children: [
            Icon(Icons.credit_card, color: c.primary, size: 22),
            const SizedBox(width: AppSpacing.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    textDirection: TextDirection.ltr,
                    children: [
                      Text('•••• ${card.last4}',
                          style: AppTypography.bodyStrong(c.textMain)
                              .copyWith(letterSpacing: 1.2)),
                      const SizedBox(width: 8),
                      CardNetworkBadge(network: card.network, height: 16),
                    ],
                  ),
                  Text(
                    '$title · ${card.source == CardSource.auto ? 'تلقائية' : 'يدوية'}',
                    style: AppTypography.caption(c.textLight),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'تعديل',
              icon: Icon(Icons.edit_outlined, color: c.textLight, size: 20),
              onPressed: () =>
                  showCardForm(context, ref, accountId: accountId, card: card),
            ),
          ],
        ),
      ),
    );
  }
}
