import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/currency.dart';
import '../../domain/finance/money_format.dart';
import '../../domain/finance/money.dart';
import '../../domain/entities/card_summary.dart';
import '../common/app_header.dart';
import '../common/category_catalog.dart';
import '../common/widgets.dart';
import '../../engine/parser/card_network.dart';
import 'card_network_badge.dart';
import 'card_theme.dart';
import 'cards_providers.dart';
import '../../core/utils/app_lucide_icons.dart';

/// شاشة تفاصيل البطاقة (بآخر 4 أرقام): بطاقة مُشتقّة من العمليات، تُفتح عبر
/// المسار `/card/:last4`. كانت سابقًا bottom sheet زجاجية بارتفاع 86% —
/// حُوِّلت لشاشة مسارية كاملة لاتّساق التنقّل ورجوع صحيح.
class CardDetailsScreen extends ConsumerWidget {
  const CardDetailsScreen({super.key, required this.last4});

  final String last4;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppHeader(title: 'بطاقة •••• $last4'),
      body: _CardDetailsContent(last4: last4),
    );
  }
}

class _CardDetailsContent extends ConsumerWidget {
  const _CardDetailsContent({required this.last4});

  final String last4;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final summaries = ref.watch(cardSummariesProvider).valueOrNull;
    final txAsync = ref.watch(cardTransactionsProvider(last4));
    final catalog = ref.watch(categoryCatalogProvider).valueOrNull;
    final displayCurrency =
        ref.watch(baseCurrencyProvider).valueOrNull ?? 'SAR';

    final matchingSummaries = summaries
            ?.where((summary) => summary.last4 == last4)
            .toList(growable: false) ??
        const <CardSummary>[];
    final displayCurrencySummary = matchingSummaries
        .where((summary) =>
            summary.currency.toUpperCase() == displayCurrency.toUpperCase())
        .firstOrNull;
    final summary = displayCurrencySummary ?? matchingSummaries.firstOrNull;

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.gutter),
      children: [
        _CardHeader(
          last4: last4,
          network: summary?.network ?? CardNetwork.unknown,
          totalIn: summary?.totalIn ?? Money.zero(displayCurrency),
          totalOut: summary?.totalOut ?? Money.zero(displayCurrency),
          colorTheme: summary?.colorTheme,
          accentHex: summary?.accentHex,
          // MALI-074n: the summary's own currency (the totals are per-currency),
          // not a guess from the first transaction row.
          currency: (summary?.currency.isNotEmpty ?? false)
              ? summary!.currency
              : displayCurrency,
        ),
        const SizedBox(height: AppSpacing.s4),
        Text('عمليات هذه البطاقة',
            style: AppTypography.sectionTitle(c.textMain)),
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
    );
  }
}

class _CardHeader extends StatelessWidget {
  const _CardHeader({
    required this.last4,
    required this.network,
    required this.totalIn,
    required this.totalOut,
    required this.currency,
    this.colorTheme,
    this.accentHex,
  });

  final String last4;
  final CardNetwork network;
  final Money totalIn;
  final Money totalOut;
  final String currency;
  final String? colorTheme;
  final String? accentHex;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s5),
      decoration: BoxDecoration(
        gradient:
            cardGradient(context, themeKey: colorTheme, accentHex: accentHex),
        borderRadius: BorderRadius.circular(AppRadius.card),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.22),
            blurRadius: 22,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(AppLucideIcons.wifi,
                  color: Colors.white.withValues(alpha: 0.8)),
              const Spacer(),
              CardNetworkBadge(network: network, height: 26),
            ],
          ),
          const SizedBox(height: AppSpacing.s5),
          Directionality(
            textDirection: TextDirection.ltr,
            child: Text('••••  ••••  ••••  $last4',
                style: AppTypography.title2(Colors.white)
                    .copyWith(letterSpacing: 2)),
          ),
          const SizedBox(height: AppSpacing.s5),
          Row(
            children: [
              _flow('داخل', totalIn, c.success),
              const SizedBox(width: AppSpacing.s6),
              _flow('خارج', totalOut, Colors.white),
            ],
          ),
        ],
      ),
    );
  }

  Widget _flow(String label, Money value, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.6),
                fontSize: 12,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 2),
        Text(
            '${formatMoneyAmount(value.toDouble(), currency)} '
            '${Currency.arabicLabel(currency)}',
            style: TextStyle(
                color: color, fontSize: 17, fontWeight: FontWeight.w700)),
      ],
    );
  }
}
