import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/session/app_session.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/utils/l10n_ext.dart';
import '../../domain/entities/transaction_entity.dart';
import '../common/category_catalog.dart';
import '../dashboard/dashboard_providers.dart';
import '../transactions/transactions_providers.dart';
import '../transactions/widgets/change_category_sheet.dart';
import '../transactions/widgets/confirm_transaction_sheet.dart';
import 'widgets/premium_ui.dart';

TextStyle _alex(double size, FontWeight weight, double height, Color color,
    {bool tabular = false}) {
  return GoogleFonts.alexandria(
    fontSize: size,
    fontWeight: weight,
    height: height,
    color: color,
    fontFeatures: tabular ? const [FontFeature.tabularFigures()] : null,
  );
}

class FirstTransactionScreen extends ConsumerWidget {
  const FirstTransactionScreen({super.key, required this.transactionId});

  final String transactionId;

  Future<void> _finish(BuildContext context) async {
    await AppSession.instance.finishOnboarding();
    if (context.mounted) context.go('/');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final txAsync = ref.watch(transactionByIdProvider(transactionId));
    final catalogAsync = ref.watch(categoryCatalogProvider);

    return PremiumBackground(
      child: SafeArea(
        child: txAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, __) => _ErrorView(onContinue: () => _finish(context)),
          data: (tx) {
            if (tx == null) return _ErrorView(onContinue: () => _finish(context));
            final catalog = catalogAsync.valueOrNull;
            if (tx.status == TransactionStatus.pending) {
              return _PendingView(
                tx: tx,
                onConfirmed: () => _finish(context),
              );
            }
            return _ConfirmedView(
              tx: tx,
              catalog: catalog,
              onContinue: () => _finish(context),
            );
          },
        ),
      ),
    );
  }
}

// ── Confirmed ────────────────────────────────────────────────────────────────

class _ConfirmedView extends ConsumerWidget {
  const _ConfirmedView({
    required this.tx,
    required this.catalog,
    required this.onContinue,
  });

  final TransactionEntity tx;
  final CategoryCatalog? catalog;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final cat = catalog?.byId(tx.categoryId);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 32),
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: c.success.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(99),
                border: Border.all(color: c.success.withValues(alpha: 0.28)),
              ),
              child: Text(
                context.l10n.firstTxTitle,
                style: _alex(13, FontWeight.w800, 1.2, c.success),
              ),
            ),
          ),
          const SizedBox(height: 24),
          GlassCard(
            padding: const EdgeInsets.all(22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (cat != null)
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: cat.color.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Icon(cat.icon, color: cat.color, size: 24),
                      ),
                    if (cat != null) const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            tx.rawMerchant ?? tx.rawMessage.split('\n').first,
                            style: _alex(16, FontWeight.w800, 1.2, c.textMain),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (cat != null)
                            Text(
                              cat.nameAr,
                              style: _alex(12, FontWeight.w600, 1.3, c.textLight),
                            ),
                        ],
                      ),
                    ),
                    Text(
                      '${tx.amount.toStringAsFixed(2)} ${tx.currency}',
                      style: _alex(17, FontWeight.w800, 1.2, c.textMain,
                          tabular: true),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _SourceChip(source: tx.source),
                if (cat != null) ...[
                  const SizedBox(height: 16),
                  GestureDetector(
                    onTap: () async {
                      final loadedCatalog = catalog;
                      if (loadedCatalog == null) return;
                      await showChangeCategorySheet(context, tx, loadedCatalog);
                      ref.invalidate(transactionByIdProvider(tx.id));
                      ref.invalidate(dashboardDataProvider);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: c.accent.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(99),
                        border:
                            Border.all(color: c.accent.withValues(alpha: 0.2)),
                      ),
                      child: Text(
                        context.l10n.wrongCategoryTap,
                        style: _alex(11, FontWeight.w700, 1.2, c.accent),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          GlassCard(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Text(
              context.l10n.firstTxTrustLine,
              textAlign: TextAlign.center,
              style: _alex(13, FontWeight.w600, 1.5, c.textLight),
            ),
          ),
          const Spacer(),
          SizedBox(
            height: 54,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: maliPrimaryActionGradient(context),
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: c.accent.withValues(alpha: 0.28),
                    blurRadius: 18,
                    offset: const Offset(0, 7),
                  ),
                ],
              ),
              child: ElevatedButton(
                onPressed: onContinue,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.transparent,
                  shadowColor: Colors.transparent,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                ),
                child: Text(
                  context.l10n.firstTxContinue,
                  style: _alex(16, FontWeight.w800, 1.2,
                      maliPrimaryActionForeground(context)),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

// ── Pending ──────────────────────────────────────────────────────────────────

class _PendingView extends ConsumerWidget {
  const _PendingView({required this.tx, required this.onConfirmed});

  final TransactionEntity tx;
  final VoidCallback onConfirmed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 48),
          Center(
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: c.accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(99),
                border:
                    Border.all(color: c.accent.withValues(alpha: 0.28)),
              ),
              child: Text(
                context.l10n.firstTxNeedsCheck,
                style: _alex(13, FontWeight.w800, 1.2, c.accent),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            context.l10n.firstTxNeedsCheckSub,
            textAlign: TextAlign.center,
            style: _alex(15, FontWeight.w500, 1.5, c.textLight),
          ),
          const Spacer(),
          SizedBox(
            height: 54,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: maliPrimaryActionGradient(context),
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: c.accent.withValues(alpha: 0.28),
                    blurRadius: 18,
                    offset: const Offset(0, 7),
                  ),
                ],
              ),
              child: ElevatedButton(
                onPressed: () async {
                  await showConfirmTransactionSheet(context, tx.id);
                  onConfirmed();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.transparent,
                  shadowColor: Colors.transparent,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                ),
                child: Text(
                  context.l10n.firstTxNeedsCheck,
                  style: _alex(16, FontWeight.w800, 1.2,
                      maliPrimaryActionForeground(context)),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

// ── Source chip ──────────────────────────────────────────────────────────────

class _SourceChip extends StatelessWidget {
  const _SourceChip({required this.source});
  final TransactionSourceEntity source;

  String _label(BuildContext context) {
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    switch (source) {
      case TransactionSourceEntity.bank:
        return isAr ? 'تحويل بنكي' : 'Bank transfer';
      case TransactionSourceEntity.card:
        return isAr ? 'بطاقة' : 'Card';
      case TransactionSourceEntity.wallet:
        return isAr ? 'محفظة' : 'Wallet';
      case TransactionSourceEntity.unknown:
        return 'SMS';
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      children: [
        Icon(Icons.sms_outlined, size: 13, color: c.textLight),
        const SizedBox(width: 6),
        Text(
          _label(context),
          style: GoogleFonts.alexandria(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: c.textLight),
        ),
      ],
    );
  }
}

// ── Error fallback ────────────────────────────────────────────────────────────

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.onContinue});
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.gutter),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Spacer(),
          Text(
            context.l10n.firstTxContinue,
            style: GoogleFonts.alexandria(
                fontSize: 16, fontWeight: FontWeight.w700, color: c.textMain),
          ),
          const Spacer(),
          SizedBox(
            height: 52,
            width: double.infinity,
            child: ElevatedButton(
              onPressed: onContinue,
              child: Text(context.l10n.firstTxContinue),
            ),
          ),
        ],
      ),
    );
  }
}
