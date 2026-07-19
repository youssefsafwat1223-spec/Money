import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/navy_sheet_theme.dart';
import '../cards/brand_mark.dart';
import '../common/top_banner.dart';
import 'coupon_models.dart';

class CouponCard extends StatelessWidget {
  const CouponCard({
    super.key,
    required this.offer,
    this.compact = false,
    this.onTap,
  });

  final CouponOffer offer;
  final bool compact;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap ?? () => showCouponDetailsSheet(context, offer),
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: Container(
          width: compact ? 260 : null,
          padding: const EdgeInsets.all(AppSpacing.s4),
          decoration: BoxDecoration(
            color: c.surfaceCard,
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(color: c.border),
            boxShadow: [
              BoxShadow(
                color: offer.accent.withValues(alpha: 0.10),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  BrandMark(name: offer.partnerName, size: 42),
                  const SizedBox(width: AppSpacing.s3),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          offer.partnerName,
                          style: AppTypography.caption(c.textMuted)
                              .copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          offer.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.bodyStrong(c.textPrimary),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.s3),
              Text(
                offer.description,
                maxLines: compact ? 2 : 3,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.footnote(c.textSecondary),
              ),
              const SizedBox(height: AppSpacing.s3),
              Row(
                children: [
                  Expanded(child: _CouponCodePill(code: offer.code)),
                  const SizedBox(width: AppSpacing.s2),
                  _ExpiryPill(offer: offer),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CouponCodePill extends StatelessWidget {
  const _CouponCodePill({required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: c.ctaSoft,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: c.cta.withValues(alpha: 0.18)),
      ),
      child: Text(
        code,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textDirection: TextDirection.ltr,
        style: AppTypography.caption(c.cta).copyWith(
          fontWeight: FontWeight.w900,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _ExpiryPill extends StatelessWidget {
  const _ExpiryPill({required this.offer});

  final CouponOffer offer;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final days =
        offer.validUntil.difference(DateTime.now()).inDays.clamp(0, 999);
    final color = offer.expiresSoon ? c.warning : c.textMuted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        days == 0 ? 'ينتهي اليوم' : '$days يوم',
        style:
            AppTypography.caption(color).copyWith(fontWeight: FontWeight.w800),
      ),
    );
  }
}

Future<void> showCouponDetailsSheet(BuildContext context, CouponOffer offer) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => navySheetTheme(_CouponDetailsSheet(offer: offer)),
  );
}

class _CouponDetailsSheet extends StatelessWidget {
  const _CouponDetailsSheet({required this.offer});

  final CouponOffer offer;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(AppSpacing.s3),
        padding: const EdgeInsets.all(AppSpacing.s5),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(AppRadius.sheet),
          border: Border.all(color: c.border),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                BrandMark(name: offer.partnerName, size: 54),
                const SizedBox(width: AppSpacing.s3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(offer.partnerName,
                          style: AppTypography.caption(c.textMuted)),
                      Text(offer.title,
                          style: AppTypography.title(c.textPrimary)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.s4),
            Text(offer.description,
                style: AppTypography.callout(c.textSecondary)),
            const SizedBox(height: AppSpacing.s4),
            _CouponCodePill(code: offer.code),
            const SizedBox(height: AppSpacing.s4),
            FilledButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: offer.code));
                if (context.mounted) {
                  showTopInfo(context, 'تم نسخ الكوبون ${offer.code}');
                }
              },
              icon: const Icon(Icons.copy_rounded),
              label: const Text('نسخ الكوبون'),
            ),
            if (offer.partnerUrl != null) ...[
              const SizedBox(height: AppSpacing.s2),
              OutlinedButton.icon(
                onPressed: () => launchUrl(
                  Uri.parse(offer.partnerUrl!),
                  mode: LaunchMode.externalApplication,
                ),
                icon: const Icon(Icons.open_in_new_rounded),
                label: const Text('فتح الشريك'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
