import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/l10n_ext.dart';
import '../../domain/finance/money.dart';
import '../../domain/finance/money_format.dart';
import '../common/widgets.dart';
import 'savings_math.dart';
import 'savings_providers.dart';
import 'savings_repository.dart';

/// COUPONS Phase 4 — what the user saved.
///
/// ## The breakdown is the feature
///
/// It would be easy to show one big number. It would also be indefensible: a
/// total built from a user's own estimates and a store's confirmed figures is a
/// claim the app cannot stand behind, and the first time someone checks an entry
/// and finds it was a guess, every other number here loses its credibility.
///
/// So the three evidence kinds are always shown separately, always labelled, and
/// the note says plainly that they are not equally certain. The confirmed figure
/// is the one we can defend without qualification, and it is the one presented
/// as such.
///
/// Currencies are likewise never combined — there is no FX design, and a sum
/// across currencies would be a number in no currency at all.
class SavingsScreen extends ConsumerWidget {
  const SavingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final c = context.colors;
    final totals = ref.watch(savingsTotalsProvider);

    return AppScreenScaffold(
      header: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter, AppSpacing.s3, AppSpacing.gutter, AppSpacing.s2),
        child: Row(
          children: [
            Expanded(
              child: Text(
                l10n.savingsTitle,
                style: AppTypography.calmTitle(c.textPrimary)
                    .copyWith(fontSize: 24, letterSpacing: -0.5),
              ),
            ),
            IconButton(
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(AppLucideIcons.x),
            ),
          ],
        ),
      ),
      body: totals.when(
        skipLoadingOnReload: true,
        loading: () => AppLoadingState(label: l10n.couponsLoading),
        error: (_, __) => AppErrorState(
          title: l10n.couponsErrorTitle,
          description: l10n.couponsErrorBody,
          retryLabel: l10n.couponsRetry,
          onRetry: () => ref.invalidate(savingsTotalsProvider),
        ),
        data: (data) {
          if (data.isEmpty) {
            return AppEmptyState(
              icon: AppLucideIcons.badgeCheck,
              title: l10n.savingsEmptyTitle,
              subtitle: l10n.savingsEmptyBody,
            );
          }
          final currencies = data.byCurrencyAndEvidence.keys.toList()..sort();
          return ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutter, AppSpacing.s2, AppSpacing.gutter, 120),
            children: [
              for (final currency in currencies) ...[
                _CurrencyBlock(currency: currency, totals: data),
                const SizedBox(height: AppSpacing.s4),
              ],
              Text(
                l10n.savingsBreakdownNote,
                style: AppTypography.caption(c.textMuted),
              ),
              const SizedBox(height: 4),
              if (currencies.length > 1)
                Text(
                  l10n.savingsCurrencyNote,
                  style: AppTypography.caption(c.textMuted),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _CurrencyBlock extends StatelessWidget {
  const _CurrencyBlock({required this.currency, required this.totals});

  final String currency;
  final SavingsTotals totals;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    final byEvidence = totals.byCurrencyAndEvidence[currency] ?? const {};

    String money(int minor) {
      try {
        return formatMoney(Money(minor, currency));
      } catch (_) {
        // A currency the money layer cannot scale. Showing the raw integer
        // would be a number off by a factor of a hundred; showing nothing is
        // correct.
        return '';
      }
    }

    // Ordered strongest-evidence first. The number the app can defend without
    // qualification leads, rather than the largest one.
    const order = [
      SavingsEvidence.conversionVerified,
      SavingsEvidence.conversionEstimated,
      SavingsEvidence.userConfirmed,
    ];
    String label(SavingsEvidence e) => switch (e) {
          SavingsEvidence.conversionVerified => l10n.savingsVerifiedLabel,
          SavingsEvidence.conversionEstimated => l10n.savingsEstimatedLabel,
          SavingsEvidence.userConfirmed => l10n.savingsSelfReportedLabel,
        };

    return Container(
      padding: const EdgeInsets.all(AppSpacing.s4),
      decoration: BoxDecoration(
        color: c.surfaceCard,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(currency,
              style: AppTypography.caption(c.textMuted)
                  .copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: AppSpacing.s2),
          for (final evidence in order)
            if ((byEvidence[evidence] ?? 0) > 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Icon(
                      evidence == SavingsEvidence.conversionVerified
                          ? AppLucideIcons.badgeCheck
                          : AppLucideIcons.info,
                      size: 14,
                      color: evidence == SavingsEvidence.conversionVerified
                          ? c.success
                          : c.textMuted,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(label(evidence),
                          style: AppTypography.footnote(c.textSecondary)),
                    ),
                    Text(
                      money(byEvidence[evidence]!),
                      style: AppTypography.bodyStrong(c.textPrimary),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}
