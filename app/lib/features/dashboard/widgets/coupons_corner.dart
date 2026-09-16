import 'package:flutter/material.dart';

import '../../../core/utils/l10n_ext.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/theme/mali_tokens.dart';
import '../../../core/theme/widgets/mali_card.dart';
import '../../../core/utils/app_lucide_icons.dart';
import '../../../core/utils/formatters.dart';
import '../../common/app_avatar.dart';
import '../../coupons/coupon_models.dart';

/// Home's «ركن التوفير» — the offers, gathered in one place at the END of the
/// dashboard.
///
/// It states **what the offers are**, and nothing about what they save. The
/// catalog carries no discount value (`CouponOffer` has partner, title,
/// description, code, category, tags, validity — no savings field), so any
/// "توفّر ~N ريال" would be invented. The corner earns its place by being a
/// browsable list rather than by claiming a number it cannot compute.
///
/// Last on the page on purpose: an offer is a convenience, not an obligation.
/// Putting it above the user's own money would turn the first thing they see
/// each day into an ad.
///
/// Presentation only — tapping is delegated to [onOpen] so this file never
/// touches providers or analytics.
class CouponsCorner extends StatelessWidget {
  const CouponsCorner({
    super.key,
    required this.offers,
    required this.preferEnglish,
    required this.onOpen,
    this.onSeeAll,
  });

  final List<CouponOffer> offers;
  final bool preferEnglish;
  final void Function(CouponOffer offer) onOpen;
  final VoidCallback? onSeeAll;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = MaliTokens.of(context);
    if (offers.isEmpty) return const SizedBox.shrink();

    return MaliCard(
      style: MaliSurfaceStyle.floating,
      padding: EdgeInsets.zero,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(context, c, t),
          Divider(height: 1, color: t.strokeSoft),
          for (var i = 0; i < offers.length; i++) ...[
            if (i > 0)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Divider(height: 1, color: t.strokeSoft),
              ),
            _row(context, c, t, offers[i]),
          ],
          if (onSeeAll != null) ...[
            Divider(height: 1, color: t.strokeSoft),
            _seeAll(context, c),
          ],
        ],
      ),
    );
  }

  Widget _header(BuildContext context, AppColors c, MaliTokens t) => Padding(
        padding: const EdgeInsets.all(AppSpacing.s4),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                // The accent is TRIM here, never a text bed: gold on the tile,
                // ink in every label. The light-theme accent is too pale to
                // carry text, and a second gold token is not worth minting for
                // one chip.
                color: c.accent.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(AppLucideIcons.tag,
                  size: 18, color: t.textOnCanvasPrimary),
            ),
            const SizedBox(width: AppSpacing.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${offers.length} ${offers.length == 1 ? 'كوبون متاح' : 'كوبونات متاحة'}',
                    style:
                        AppTypography.bodyStrong(t.textOnCanvasPrimary),
                  ),
                  const SizedBox(height: 2),
                  Text(context.l10n.homePartnerOffers,
                      style: AppTypography.caption(t.textOnCanvasMuted)),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _row(
    BuildContext context,
    AppColors c,
    MaliTokens t,
    CouponOffer offer,
  ) {
    final expiry = offer.validUntil;
    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onOpen(offer),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.s4, vertical: AppSpacing.s3),
            child: Row(
              children: [
                AppAvatar.brand(
                    name: offer.partnerName, size: AppSpacing.avatarSm),
                const SizedBox(width: AppSpacing.s3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(offer.partnerName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.caption(t.textOnCanvasMuted)),
                      const SizedBox(height: 1),
                      Text(
                        offer.title(preferEnglish: preferEnglish),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.subhead(t.textOnCanvasPrimary),
                      ),
                      if (expiry != null) ...[
                        const SizedBox(height: 3),
                        Text(
                          context.l10n.homeCouponExpires(Formatters.dateGroupLabel(expiry, context)),
                          style: AppTypography.micro(t.textOnCanvasMuted),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.s3),
                _tail(context, c, t, offer),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// A code offer shows its code; a link offer has none, so it shows its
  /// category instead of an empty slot that would look like a missing value.
  Widget _tail(
    BuildContext context,
    AppColors c,
    MaliTokens t,
    CouponOffer offer,
  ) {
    final code = offer.code;
    if (code == null || code.isEmpty) {
      return Icon(AppLucideIcons.chevronLeft,
          size: 20, color: t.textOnCanvasMuted);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: c.accent.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.accent.withValues(alpha: 0.34)),
      ),
      child: Text(
        code,
        maxLines: 1,
        textDirection: TextDirection.ltr,
        style: AppTypography.custom(
          size: 11,
          weight: FontWeight.w700,
          height: 1.3,
          color: t.textOnCanvasPrimary,
        ),
      ),
    );
  }

  Widget _seeAll(BuildContext context, AppColors c) => Semantics(
        button: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onSeeAll,
          child: Container(
            constraints: const BoxConstraints(minHeight: 44),
            alignment: Alignment.center,
            child: Text(context.l10n.homeAllCoupons,
                style: AppTypography.subhead(c.cta)),
          ),
        ),
      );
}
