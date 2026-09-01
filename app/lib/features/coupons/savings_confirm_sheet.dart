import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/l10n_ext.dart';
import '../../domain/finance/money.dart';
import '../../domain/finance/money_format.dart';
import 'coupon_models.dart';
import 'savings_math.dart';
import 'savings_providers.dart';

/// COUPONS Phase 4 — "did you use this offer?"
///
/// The user supplies their basket total and we apply the offer's own terms. The
/// arithmetic is theirs; we only do it accurately.
///
/// ## Why this asks instead of assuming
///
/// The alternative — recording a saving when someone taps a coupon — would count
/// offers people looked at and never used. Every one of those inflates a total
/// the user cannot check, and the first time they notice, the whole figure stops
/// meaning anything. Asking costs a tap and buys a number that is true.
///
/// When the offer's value cannot be computed exactly, the sheet says so and
/// records NOTHING. There is no path here that writes a guess.
Future<void> showSavingsConfirmSheet(
  BuildContext context,
  WidgetRef ref,
  CouponOffer offer, {
  String? merchantId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _SavingsConfirmSheet(offer: offer, merchantId: merchantId),
  );
}

class _SavingsConfirmSheet extends ConsumerStatefulWidget {
  const _SavingsConfirmSheet({required this.offer, this.merchantId});

  final CouponOffer offer;
  final String? merchantId;

  @override
  ConsumerState<_SavingsConfirmSheet> createState() => _SavingsConfirmSheetState();
}

class _SavingsConfirmSheetState extends ConsumerState<_SavingsConfirmSheet> {
  final _controller = TextEditingController();
  SavingsOutcome? _preview;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _recompute() {
    final currency = widget.offer.benefitCurrency;
    if (currency == null) {
      setState(() => _preview =
          const SavingsOutcome.abstained(SavingsAbstention.noStructuredBenefit));
      return;
    }
    Money? basket;
    try {
      basket = Money.parse(_controller.text.trim(), currency);
    } catch (_) {
      basket = null;
    }
    setState(() {
      _preview = basket == null
          ? const SavingsOutcome.abstained(SavingsAbstention.invalidBasket)
          : SavingsMath.fromUserConfirmation(
              widget.offer,
              basketMinor: basket.minorUnits,
              basketCurrency: currency,
            );
    });
  }

  Future<void> _save() async {
    final outcome = _preview;
    // Guarded twice: the button is disabled without an amount, and the
    // repository refuses an abstention. A saving must never be written from a
    // figure we could not compute.
    if (outcome == null || !outcome.hasAmount) return;
    await ref.read(savingsRepositoryProvider).record(
          outcome,
          couponId: widget.offer.id,
          merchantId: widget.merchantId ?? widget.offer.merchantId,
        );
    ref.invalidate(savingsTotalsProvider);
    ref.invalidate(savingsHistoryProvider);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    final preview = _preview;
    final canSave = preview != null && preview.hasAmount;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.s5),
        decoration: BoxDecoration(
          color: c.surfaceCard,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.savingsConfirmTitle,
                style: AppTypography.bodyStrong(c.textPrimary)),
            const SizedBox(height: 4),
            // States plainly that the calculation is local. A user being asked
            // about a purchase deserves to know it is not being reported.
            Text(l10n.savingsConfirmBody,
                style: AppTypography.caption(c.textSecondary)),
            const SizedBox(height: AppSpacing.s4),
            TextField(
              controller: _controller,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              onChanged: (_) => _recompute(),
              decoration: InputDecoration(
                labelText: l10n.savingsConfirmAmountLabel,
                suffixText: widget.offer.benefitCurrency,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpacing.s3),
            if (preview != null && preview.hasAmount)
              Text(
                formatMoney(Money(preview.amountMinor!, preview.currency!)),
                style: AppTypography.calmTitle(c.cta).copyWith(fontSize: 24),
              )
            else if (preview != null)
              // The honest outcome, stated rather than hidden behind a disabled
              // button with no explanation.
              Text(l10n.savingsCannotCompute,
                  style: AppTypography.caption(c.textMuted)),
            const SizedBox(height: AppSpacing.s4),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: canSave ? _save : null,
                child: Text(l10n.savingsConfirmAction),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
