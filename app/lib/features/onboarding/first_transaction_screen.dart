import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/utils/l10n_ext.dart';
import '../../domain/entities/transaction_entity.dart';
import '../common/category_catalog.dart';
import '../dashboard/dashboard_providers.dart';
import '../transactions/transactions_providers.dart';
import '../transactions/widgets/change_category_sheet.dart';
import '../transactions/widgets/confirm_transaction_sheet.dart';
import '../common/app_button.dart';
import 'widgets/neon_illustration.dart';
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
    if (context.mounted) context.go('/onboarding/completion');
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
            if (tx == null) {
              return _ErrorView(onContinue: () => _finish(context));
            }
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
            child: NeonIllustration(
              icon: Icons.check_circle_outline_rounded,
              color: c.success,
              size: 140,
            ).animate().fade(duration: 800.ms).scale(curve: Curves.easeOutBack),
          ),
          const SizedBox(height: 16),
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
          const SizedBox(height: 14),
          Text(
            'كده قرش بدأ يفهم مصروفاتك',
            textAlign: TextAlign.center,
            style: _alex(26, FontWeight.w800, 1.18, c.textMain),
          ),
          const SizedBox(height: 8),
          Text(
            context.l10n.firstTxTrustLine,
            textAlign: TextAlign.center,
            style: _alex(13, FontWeight.w600, 1.5, c.textLight),
          ),
          const SizedBox(height: 22),
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
                              style:
                                  _alex(12, FontWeight.w600, 1.3, c.textLight),
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
          _MiniTrustStrip(),
          const Spacer(),
          AppPrimaryButton(
            label: 'رائع!',
            onTap: onContinue,
            height: 56,
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 48),
          OnboardingHeroCard(
            icon: Icons.rule_rounded,
            title: context.l10n.firstTxNeedsCheck,
            subtitle: context.l10n.firstTxNeedsCheckSub,
          ),
          const SizedBox(height: 20),
          GlassCard(
            padding: const EdgeInsets.all(18),
            child: Column(
              children: [
                _PendingInfoRow(
                  icon: Icons.receipt_long_outlined,
                  title: tx.rawMerchant ?? tx.rawMessage.split('\n').first,
                  subtitle: '${tx.amount.toStringAsFixed(2)} ${tx.currency}',
                ),
                const SizedBox(height: 14),
                const _PendingInfoRow(
                  icon: Icons.category_outlined,
                  title: 'مراجعة سريعة',
                  subtitle: 'راجع المبلغ والتصنيف مرة واحدة قبل دخول قرش.',
                ),
              ],
            ),
          ),
          const Spacer(),
          AppPrimaryButton(
            label: context.l10n.firstTxNeedsCheck,
            onTap: () async {
              await showConfirmTransactionSheet(context, tx.id);
              onConfirmed();
            },
            height: 56,
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _MiniTrustStrip extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final items = [
      (Icons.check_circle_outline_rounded, 'اتسجّلت'),
      (Icons.edit_note_rounded, 'تقدر تعدّل'),
      (Icons.lock_outline_rounded, 'خصوصية'),
    ];
    return Row(
      children: [
        for (var i = 0; i < items.length; i++) ...[
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: c.surfaceCard,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: c.border),
              ),
              child: Column(
                children: [
                  Icon(items[i].$1, size: 17, color: c.success),
                  const SizedBox(height: 5),
                  Text(
                    items[i].$2,
                    style: _alex(10, FontWeight.w800, 1.1, c.textMain),
                  ),
                ],
              ),
            ),
          ),
          if (i != items.length - 1) const SizedBox(width: 8),
        ],
      ],
    );
  }
}

class _PendingInfoRow extends StatelessWidget {
  const _PendingInfoRow({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: c.accent.withValues(alpha: 0.11),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: c.accent.withValues(alpha: 0.22)),
          ),
          child: Icon(icon, color: c.accent, size: 21),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _alex(13, FontWeight.w800, 1.2, c.textMain),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style:
                    _alex(12, FontWeight.w700, 1.3, c.textLight, tabular: true),
              ),
            ],
          ),
        ),
      ],
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
      case TransactionSourceEntity.aiParsed:
        return isAr ? 'ذكاء اصطناعي' : 'AI Parsed';
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
              fontSize: 11, fontWeight: FontWeight.w700, color: c.textLight),
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
          GlowingIcon(
            icon: Icons.receipt_long_outlined,
            color: c.warning,
            size: 34,
          ),
          const SizedBox(height: 18),
          Text(
            'هنكمل ونظبطها بعدين',
            textAlign: TextAlign.center,
            style: _alex(22, FontWeight.w800, 1.2, c.textMain),
          ),
          const SizedBox(height: 8),
          Text(
            'لم نتمكن من عرض أول عملية الآن، لكن تقدر تدخل قرش وتضيف أو تراجع العملية يدوياً.',
            textAlign: TextAlign.center,
            style: _alex(13, FontWeight.w600, 1.5, c.textLight),
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
