import 'package:flutter/material.dart';
import '../common/money_text.dart';
import '../../domain/finance/money.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/calm_page_header.dart';
import '../../core/theme/widgets/mali_card.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/account_entity.dart';
import '../../domain/entities/card_summary.dart';
import '../cards/bank_mark.dart';
import '../cards/card_network_badge.dart';
import '../cards/mini_card_art.dart';
import '../cards/cards_providers.dart';
import 'account_form_sheet.dart';
import '../../core/di/app_providers.dart';
import '../../core/utils/app_lucide_icons.dart';

class AccountsScreen extends ConsumerWidget {
  const AccountsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final accountsAsync = ref.watch(accountsProvider);
    final unassigned =
        ref.watch(accountCardGroupsProvider).valueOrNull?.unassigned ??
            const <CardSummary>[];
    return Scaffold(
      backgroundColor: c.bg,
      body: Column(
        children: [
          const _AccountsHeader(),
          Expanded(
            child: accountsAsync.when(
              skipLoadingOnReload: true,
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => const Center(child: Text('حدث خطأ')),
              data: (accounts) => ListView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.gutter,
                  AppSpacing.s4,
                  AppSpacing.gutter,
                  120,
                ),
                children: [
                  _CurrencyTotals(accounts: accounts),
                  for (final account in accounts) ...[
                    _AccountCard(account: account),
                    const SizedBox(height: AppSpacing.s3),
                  ],
                  const SizedBox(height: AppSpacing.s3),
                  OutlinedButton.icon(
                    onPressed: () => showAccountForm(context, ref),
                    icon: const Icon(AppLucideIcons.plus),
                    label: const Text('إضافة حساب'),
                    style: OutlinedButton.styleFrom(
                      minimumSize:
                          const Size.fromHeight(AppSpacing.buttonHeight),
                      side: BorderSide(color: c.primary.withValues(alpha: 0.4)),
                    ),
                  ),
                  if (unassigned.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.s5),
                    _UnassignedCardsSection(cards: unassigned),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// UX-013 — totals, grouped BY CURRENCY.
///
/// A single "total across accounts" is not available to this app: summing money
/// of different currencies is forbidden by the financial-semantics contract and
/// there is no FX layer. Grouping is the honest form of the same answer — it
/// tells the user how much they have without inventing a rate.
class _CurrencyTotals extends StatelessWidget {
  const _CurrencyTotals({required this.accounts});

  final List<AccountEntity> accounts;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final totals = <String, int>{};
    for (final a in accounts) {
      final m = a.currentBalanceMoney;
      if (m == null) continue;
      totals[m.currency] = (totals[m.currency] ?? 0) + m.minorUnits;
    }
    if (totals.isEmpty) return const SizedBox.shrink();

    final entries = totals.entries.toList()
      ..sort((x, y) => y.value.abs().compareTo(x.value.abs()));

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s3),
      child: Wrap(
        spacing: AppSpacing.s2,
        runSpacing: AppSpacing.s2,
        children: [
          for (final e in entries)
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.s3, vertical: 6),
              decoration: BoxDecoration(
                color: c.primary.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  MoneyText(
                    Money(e.value, e.key),
                    style: AppTypography.caption(
                      e.value < 0 ? c.warning : c.primary,
                    ).copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(width: 3),
                  Text(
                    Currency.arabicLabel(e.key),
                    style: AppTypography.caption(
                      e.value < 0 ? c.warning : c.primary,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _AccountsHeader extends StatelessWidget {
  const _AccountsHeader();

  @override
  Widget build(BuildContext context) {
    return CalmPageHeader(
      title: 'الحسابات والمحافظ',
      subtitle: 'كل حساب بعملته الخاصة — نقدي، بنك، محفظة أو بطاقة.',
      leading: Navigator.of(context).canPop()
          ? const BackButton(color: Colors.white)
          : null,
    );
  }
}

class _AccountCard extends ConsumerWidget {
  const _AccountCard({required this.account});

  final AccountEntity account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => context.push('/account/${account.id}'),
      child: MaliCard(
        style: MaliSurfaceStyle.floating,
        padding: const EdgeInsets.all(AppSpacing.s4),
        child: Row(
          children: [
            // بنك/بطاقة = بطاقة مصغّرة واقعية؛ كاش/محفظة تفضل بعلامة النوع —
            // مفيش بطاقة فيزيائية تتمثّل.
            if (account.type == AccountType.bank ||
                account.type == AccountType.card)
              MiniCardArt(
                width: 54,
                themeKey:
                    account.type == AccountType.bank ? 'navy' : 'graphite',
              )
            else
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
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          account.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.bodyStrong(c.textMain),
                        ),
                      ),
                      if (account.isDefault) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: c.primary.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(AppRadius.pill),
                          ),
                          child: Text('افتراضي',
                              style: AppTypography.caption(c.primary)
                                  .copyWith(fontWeight: FontWeight.w700)),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${accountTypeLabel(account.type)} · ${Currency.arabicLabel(account.currency)} (${account.currency})',
                    style: AppTypography.caption(c.textLight),
                  ),
                  // UX-013 — the balance was the one thing this screen never
                  // answered. A negative balance is normal for a credit card,
                  // so it is coloured as information rather than as an error,
                  // and carries an explicit sign so it can never read as a
                  // positive figure.
                  if (account.currentBalanceMoney case final balance?) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Flexible(
                          child: MoneyText(
                            balance,
                            style: AppTypography.bodyStrong(
                              balance.minorUnits < 0 ? c.warning : c.textMain,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          Currency.arabicLabel(account.currency),
                          style: AppTypography.caption(c.textLight),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            Icon(AppLucideIcons.chevronLeft, color: c.textLight, size: 20),
          ],
        ),
      ),
    );
  }
}

/// بطاقات ظهرت في الرسائل لكن بلا حساب موثوق — متوقّع في تطبيق SMS-first.
class _UnassignedCardsSection extends StatelessWidget {
  const _UnassignedCardsSection({required this.cards});

  final List<CardSummary> cards;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('بطاقات غير مخصّصة',
            style: AppTypography.sectionTitle(c.textMain)),
        const SizedBox(height: 2),
        Text(
          'بطاقات ظهرت في رسائلك لكنها غير مرتبطة بحساب بعد.',
          style: AppTypography.caption(c.textLight),
        ),
        const SizedBox(height: AppSpacing.s3),
        for (final card in cards) ...[
          _UnassignedCardTile(card: card),
          const SizedBox(height: AppSpacing.s3),
        ],
      ],
    );
  }
}

class _UnassignedCardTile extends StatelessWidget {
  const _UnassignedCardTile({required this.card});

  final CardSummary card;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final net = card.totalIn - card.totalOut;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => context.push('/card/${card.last4}'),
      child: MaliCard(
        style: MaliSurfaceStyle.floating,
        padding: const EdgeInsets.all(AppSpacing.s4),
        child: Row(
          children: [
            Icon(AppLucideIcons.creditCard, color: c.textLight, size: 22),
            const SizedBox(width: AppSpacing.s3),
            Expanded(
              child: Row(
                textDirection: TextDirection.ltr,
                children: [
                  Text('•••• ${card.last4}',
                      style: AppTypography.bodyStrong(c.textMain)
                          .copyWith(letterSpacing: 1.5)),
                  const SizedBox(width: 8),
                  CardNetworkBadge(network: card.network, height: 18),
                ],
              ),
            ),
            Text(Formatters.amount(net.toDouble()),
                style: AppTypography.caption(c.textLight)),
            const SizedBox(width: 6),
            Icon(AppLucideIcons.chevronLeft, color: c.textLight, size: 20),
          ],
        ),
      ),
    );
  }
}
