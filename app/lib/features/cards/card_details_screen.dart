import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/card_summary.dart';
import '../common/category_catalog.dart';
import '../common/widgets.dart';
import '../../engine/parser/card_network.dart';
import 'card_network_badge.dart';
import 'cards_providers.dart';

class CardDetailsScreen extends ConsumerWidget {
  const CardDetailsScreen({super.key, required this.last4});

  final String last4;

  static Future<void> showSheet(BuildContext context, String last4) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _CardDetailsSheet(last4: last4),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: Text('بطاقة •••• $last4')),
      body: _CardDetailsContent(last4: last4),
    );
  }
}

class _CardDetailsSheet extends StatelessWidget {
  const _CardDetailsSheet({required this.last4});

  final String last4;

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
          child: Container(
            height: MediaQuery.of(context).size.height * 0.86,
            decoration: BoxDecoration(
              color: isDark ? c.surface.withValues(alpha: 0.9) : Colors.white.withValues(alpha: 0.92),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              border: Border.all(
                color: Colors.white.withValues(alpha: isDark ? 0.08 : 0.3),
                width: 1.5,
              ),
            ),
            child: Column(
              children: [
                const SizedBox(height: AppSpacing.s3),
                Container(
                  width: 44,
                  height: 5,
                  decoration: BoxDecoration(
                    color: c.textLight.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.gutter,
                    AppSpacing.s4,
                    AppSpacing.gutter,
                    AppSpacing.s2,
                  ),
                  child: Row(
                    children: [
                      Text('بطاقة •••• $last4',
                          style: AppTypography.title2(c.textMain)),
                      const Spacer(),
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                Expanded(child: _CardDetailsContent(last4: last4)),
              ],
            ),
          ),
        ),
      ),
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

    final summary = summaries?.where((s) => s.last4 == last4).fold<CardSummary?>(
          null,
          (prev, s) => s,
        );

    return ListView(
        padding: const EdgeInsets.all(AppSpacing.gutter),
        children: [
          _CardHeader(
            last4: last4,
            network: summary?.network ?? CardNetwork.unknown,
            totalIn: summary?.totalIn ?? 0,
            totalOut: summary?.totalOut ?? 0,
            currency: (txAsync.valueOrNull?.isNotEmpty ?? false)
                ? txAsync.valueOrNull!.first.currency
                : (ref.watch(baseCurrencyProvider).valueOrNull ?? 'SAR'),
          ),
          const SizedBox(height: AppSpacing.s5),
          Text('عمليات هذه البطاقة', style: AppTypography.title2(c.textMain)),
          const SizedBox(height: AppSpacing.s2),
          txAsync.when(
            loading: () => const Center(
                child: Padding(
                    padding: EdgeInsets.all(24),
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
  });

  final String last4;
  final CardNetwork network;
  final double totalIn;
  final double totalOut;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s5),
      decoration: BoxDecoration(
        gradient: c.primaryGradient,
        borderRadius: BorderRadius.circular(AppRadius.card),
        boxShadow: [
          BoxShadow(
            color: c.primary.withValues(alpha: 0.3),
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
              Icon(Icons.contactless,
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

  Widget _flow(String label, double value, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.6),
                fontSize: 12,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 2),
        Text('${Formatters.amount(value)} ${Currency.arabicLabel(currency)}',
            style: TextStyle(
                color: color, fontSize: 17, fontWeight: FontWeight.w800)),
      ],
    );
  }
}
