import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/card_summary.dart';
import 'card_details_screen.dart';
import 'card_network_badge.dart';
import 'cards_providers.dart';

/// قسم «بطاقاتي» في الـ Dashboard: كاروسيل بطاقات بصرية + الداخل/الخارج لكل بطاقة.
class CardsCarousel extends ConsumerWidget {
  const CardsCarousel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final async = ref.watch(cardSummariesProvider);
    final cards = async.valueOrNull ?? const <CardSummary>[];
    if (cards.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding:
              const EdgeInsets.fromLTRB(4, AppSpacing.s5, 4, AppSpacing.s3),
          child: Text('بطاقاتي', style: AppTypography.title2(c.textMain)),
        ),
        SizedBox(
          height: 150,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 2),
            itemCount: cards.length,
            separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.s3),
            itemBuilder: (_, i) => _CardTile(card: cards[i]),
          ),
        ),
      ],
    );
  }
}

class _CardTile extends StatelessWidget {
  const _CardTile({required this.card});

  final CardSummary card;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: () => CardDetailsScreen.showSheet(context, card.last4),
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: Container(
        width: 250,
        padding: const EdgeInsets.all(AppSpacing.s4),
        decoration: BoxDecoration(
          gradient: c.primaryGradient,
          borderRadius: BorderRadius.circular(AppRadius.card),
          boxShadow: [
            BoxShadow(
              color: c.primary.withValues(alpha: 0.3),
              blurRadius: 20,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.contactless,
                    color: Colors.white.withValues(alpha: 0.8), size: 22),
                const Spacer(),
                CardNetworkBadge(network: card.network),
              ],
            ),
            const Spacer(),
            Row(
              textDirection: TextDirection.ltr,
              children: [
                Text('•••• ${card.last4}',
                    style: AppTypography.headline(Colors.white)
                        .copyWith(letterSpacing: 2)),
              ],
            ),
            const SizedBox(height: AppSpacing.s3),
            Row(
              children: [
                _flow(context, 'داخل', card.totalIn, c.success),
                const SizedBox(width: AppSpacing.s4),
                _flow(context, 'خارج', card.totalOut,
                    Colors.white.withValues(alpha: 0.9)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _flow(BuildContext context, String label, double value, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: AppTypography.caption(Colors.white.withValues(alpha: 0.6))),
        Text(Formatters.amount(value), style: AppTypography.bodyStrong(color)),
      ],
    );
  }
}
