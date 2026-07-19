import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/navy_sheet_theme.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/card_summary.dart';
import '../../domain/entities/transaction_entity.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../common/app_screen_scaffold.dart';
import '../transactions/manual_transaction_sheet.dart';
import 'card_details_screen.dart';
import 'card_network_badge.dart';
import 'cards_providers.dart';
import '../../core/theme/widgets/app_toast.dart';

/// صفحة «بطاقاتي»: كل البطاقات + داخل/خارج/الصافي لكل بطاقة، مع إضافة عملية
/// جديدة أو ربط عملية موجودة بالبطاقة. تُفتح من كارت في الـ Dashboard/الإعدادات.
class MyCardsScreen extends ConsumerWidget {
  const MyCardsScreen({super.key});

  static Future<void> open(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const MyCardsScreen()),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final async = ref.watch(cardSummariesProvider);
    final cards = async.valueOrNull ?? const <CardSummary>[];

    return AppScreenScaffold(
      header: Padding(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.s2, AppSpacing.s3, AppSpacing.gutter, AppSpacing.s3),
        child: Row(
          children: [
            IconButton(
              icon: Icon(Icons.arrow_back_ios_new, color: c.textMain, size: 20),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            Text('بطاقاتي', style: AppTypography.title1(c.textMain)),
          ],
        ),
      ),
      body: async.isLoading
          ? const Center(child: CircularProgressIndicator())
          : cards.isEmpty
              ? _empty(context)
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.gutter,
                      AppSpacing.s2, AppSpacing.gutter, AppSpacing.s6),
                  itemCount: cards.length,
                  separatorBuilder: (_, __) =>
                      const SizedBox(height: AppSpacing.s4),
                  itemBuilder: (_, i) => _CardRow(card: cards[i]),
                ),
    );
  }

  Widget _empty(BuildContext context) {
    final c = context.colors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.gutter),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.credit_card_off, size: 48, color: c.textLight),
            const SizedBox(height: AppSpacing.s4),
            Text('مفيش بطاقات لسه', style: AppTypography.title2(c.textMain)),
            const SizedBox(height: AppSpacing.s2),
            Text(
              'البطاقات بتظهر تلقائيًا من رسائل البنك، وتقدر تضيف عملية لأي بطاقة.',
              textAlign: TextAlign.center,
              style: AppTypography.subhead(c.textLight),
            ),
          ],
        ),
      ),
    );
  }
}

class _CardRow extends ConsumerWidget {
  const _CardRow({required this.card});

  final CardSummary card;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final net = card.totalIn - card.totalOut;
    return Container(
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
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.card),
          onTap: () => CardDetailsScreen.showSheet(context, card.last4),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.s4),
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
                const SizedBox(height: AppSpacing.s5),
                Row(
                  textDirection: TextDirection.ltr,
                  children: [
                    Text('•••• ${card.last4}',
                        style: AppTypography.headline(Colors.white)
                            .copyWith(letterSpacing: 2)),
                  ],
                ),
                const SizedBox(height: AppSpacing.s4),
                Row(
                  children: [
                    _flow('داخل', card.totalIn, c.success),
                    const SizedBox(width: AppSpacing.s5),
                    _flow('خارج', card.totalOut,
                        Colors.white.withValues(alpha: 0.95)),
                    const Spacer(),
                    _flow('الصافي', net, Colors.white),
                  ],
                ),
                const SizedBox(height: AppSpacing.s4),
                Row(
                  children: [
                    Expanded(
                      child: _action(
                        icon: Icons.add,
                        label: 'إضافة عملية',
                        onTap: () => ManualTransactionSheet.show(
                          context,
                          cardLast4: card.last4,
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.s3),
                    Expanded(
                      child: _action(
                        icon: Icons.link,
                        label: 'اربط عملية موجودة',
                        onTap: () => _showAttachSheet(context, card.last4),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _action({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return TextButton.icon(
      onPressed: onTap,
      icon: Icon(icon, color: Colors.white, size: 18),
      label: Text(label,
          style: AppTypography.footnote(Colors.white),
          maxLines: 1,
          overflow: TextOverflow.ellipsis),
      style: TextButton.styleFrom(
        backgroundColor: Colors.white.withValues(alpha: 0.16),
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.s3, vertical: AppSpacing.s2),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
      ),
    );
  }

  Widget _flow(String label, double value, Color color) {
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

/// شيت اختيار عملية موجودة وربطها بالبطاقة [last4].
Future<void> _showAttachSheet(
  BuildContext context,
  String last4,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => navySheetTheme(_AttachExistingSheet(last4: last4)),
  );
}

class _AttachExistingSheet extends ConsumerWidget {
  const _AttachExistingSheet({required this.last4});

  final String last4;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final async = ref.watch(allTransactionsForPickProvider);
    final all = async.valueOrNull ?? const <TransactionEntity>[];
    // العمليات اللي لسه مش مربوطة بنفس البطاقة تظهر أولاً.
    final items = [...all]..sort((a, b) {
        final aOwn = a.cardLast4 == last4 ? 1 : 0;
        final bOwn = b.cardLast4 == last4 ? 1 : 0;
        return aOwn.compareTo(bOwn);
      });

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (_, controller) => Container(
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            const SizedBox(height: AppSpacing.s3),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: c.textLight.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.gutter),
              child: Text('اربط عملية بـ •••• $last4',
                  style: AppTypography.title2(c.textMain)),
            ),
            Expanded(
              child: async.isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : items.isEmpty
                      ? Center(
                          child: Text('مفيش عمليات',
                              style: AppTypography.subhead(c.textLight)))
                      : ListView.builder(
                          controller: controller,
                          itemCount: items.length,
                          itemBuilder: (_, i) {
                            final tx = items[i];
                            final linked = tx.cardLast4 == last4;
                            return ListTile(
                              title: Text(tx.rawMerchant ?? 'عملية',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTypography.body(c.textMain)),
                              subtitle: Text(
                                '${Formatters.amount(tx.amount)} ${tx.currency}'
                                '${tx.cardLast4 != null ? ' • •••• ${tx.cardLast4}' : ''}',
                                style: AppTypography.footnote(c.textLight),
                              ),
                              trailing: linked
                                  ? Icon(Icons.check_circle, color: c.success)
                                  : Icon(Icons.add_link, color: c.textLight),
                              onTap: linked
                                  ? null
                                  : () async {
                                      try {
                                        await ref
                                            .read(transactionRepositoryProvider)
                                            .updateCard(
                                              transactionId: tx.id,
                                              cardLast4: last4,
                                            );
                                      } on RepoException catch (e) {
                                        if (!context.mounted) return;
                                        AppToast.show(
                                            context, repoExceptionMessage(e));
                                        return;
                                      }
                                      ref.invalidate(cardSummariesProvider);
                                      ref.invalidate(
                                          allTransactionsForPickProvider);
                                      ref.invalidate(
                                          cardTransactionsProvider(last4));
                                      if (context.mounted) {
                                        Navigator.of(context).pop();
                                        AppToast.show(context,
                                            'اتربطت العملية بـ •••• $last4');
                                      }
                                    },
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}
