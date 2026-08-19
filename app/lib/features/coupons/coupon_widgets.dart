import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/navy_sheet_theme.dart';
import '../../core/utils/l10n_ext.dart';
import '../cards/brand_mark.dart';
import '../common/top_banner.dart';
import 'coupon_models.dart';
import 'coupons_providers.dart';
import '../../core/utils/app_lucide_icons.dart';

/// MALI-COUPONS (Phase C4) — Coupon presentation.
///
/// Design rules that are contractual, not cosmetic:
///   * the partner accent is DECORATIVE TRIM only (border/tint/shadow). Text is
///     never placed on an arbitrary merchant colour, because a partner-supplied
///     hex cannot be contrast-checked.
///   * artwork is optional: a missing/failed image falls back to the accent.
///   * every production string comes from ARB (no hardcoded copy).

/// Reports when [child] has been at least [threshold] visible continuously for
/// [minDuration], at most once per mount. Used for the impression rule without
/// adding a visibility package: the check runs post-frame and on scroll.
class CouponVisibilityReporter extends StatefulWidget {
  const CouponVisibilityReporter({
    super.key,
    required this.child,
    required this.onVisible,
    this.threshold = 0.5,
    this.minDuration = const Duration(milliseconds: 300),
  });

  final Widget child;
  final VoidCallback onVisible;
  final double threshold;
  final Duration minDuration;

  @override
  State<CouponVisibilityReporter> createState() =>
      _CouponVisibilityReporterState();
}

class _CouponVisibilityReporterState extends State<CouponVisibilityReporter> {
  Timer? _timer;
  bool _reported = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _evaluate());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// Fraction of the card's height currently inside the screen viewport.
  double _visibleFraction() {
    final object = context.findRenderObject();
    if (object is! RenderBox || !object.hasSize || !object.attached) return 0;
    final size = object.size;
    if (size.height <= 0) return 0;
    final top = object.localToGlobal(Offset.zero).dy;
    final bottom = top + size.height;
    final viewport = MediaQuery.maybeOf(context)?.size.height ?? 0;
    if (viewport <= 0) return 0;
    final visible = (bottom.clamp(0, viewport)) - (top.clamp(0, viewport));
    return (visible / size.height).clamp(0.0, 1.0);
  }

  void _evaluate() {
    if (_reported || !mounted) return;
    if (_visibleFraction() >= widget.threshold) {
      // Must STAY visible: a fast scroll past the card never counts.
      _timer ??= Timer(widget.minDuration, () {
        if (!mounted || _reported) return;
        if (_visibleFraction() >= widget.threshold) {
          _reported = true;
          widget.onVisible();
        }
        _timer = null;
      });
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: (_) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _evaluate());
        return false;
      },
      child: widget.child,
    );
  }
}

/// The offer card used by the Offers screen (and, compact, by the dashboard).
class CouponCard extends ConsumerWidget {
  const CouponCard({
    super.key,
    required this.offer,
    this.compact = false,
    this.onTap,
    this.highlighted = false,
  });

  final CouponOffer offer;
  final bool compact;
  final VoidCallback? onTap;
  final bool highlighted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final l10n = context.l10n;
    final english = Localizations.localeOf(context).languageCode == 'en';
    final accent = offer.accentColor ?? c.cta;

    return CouponVisibilityReporter(
      onVisible: () => unawaited(
          ref.read(couponAnalyticsProvider).recordImpression(offer.id)),
      child: Semantics(
        label: l10n.couponsCardSemantics(
          offer.partnerName,
          offer.title(preferEnglish: english),
        ),
        button: true,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap ?? () => showCouponDetailsSheet(context, ref, offer),
            borderRadius: BorderRadius.circular(AppRadius.card),
            child: Container(
              width: compact ? 260 : null,
              constraints: const BoxConstraints(minHeight: 44),
              padding: const EdgeInsets.all(AppSpacing.s4),
              decoration: BoxDecoration(
                color: c.surfaceCard,
                borderRadius: BorderRadius.circular(AppRadius.card),
                // Accent stays TRIM: border + soft shadow, never a text bed.
                border: Border.all(
                  color: highlighted ? accent : c.border,
                  width: highlighted ? 1.5 : 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: accent.withValues(alpha: 0.10),
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
                      _CouponArtwork(offer: offer, size: 42, accent: accent),
                      const SizedBox(width: AppSpacing.s3),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              offer.partnerName,
                              style: AppTypography.caption(c.textMuted)
                                  .copyWith(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              offer.title(preferEnglish: english),
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
                    offer.description(preferEnglish: english),
                    maxLines: compact ? 2 : 3,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.footnote(c.textSecondary),
                  ),
                  const SizedBox(height: AppSpacing.s3),
                  Row(
                    children: [
                      if (offer.redemptionType == CouponRedemptionType.code &&
                          offer.code != null)
                        Expanded(child: CouponCodePill(code: offer.code!))
                      else
                        Expanded(
                          child: Text(
                            offer.category.label(preferEnglish: english),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTypography.caption(c.textMuted),
                          ),
                        ),
                      const SizedBox(width: AppSpacing.s2),
                      _ExpiryPill(offer: offer),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Partner artwork with an accent fallback. Never blocks first paint and never
/// retains a large decoded bitmap (it is capped to the rendered size).
class _CouponArtwork extends StatelessWidget {
  const _CouponArtwork(
      {required this.offer, required this.size, required this.accent});

  final CouponOffer offer;
  final double size;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final url = offer.imageUrl;
    final fallback = BrandMark(name: offer.partnerName, size: size);
    if (url == null || !url.startsWith('https://')) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.28),
      child: Image.network(
        url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        cacheWidth: (size * 3).round(),
        errorBuilder: (_, __, ___) => fallback,
        loadingBuilder: (context, child, progress) =>
            progress == null ? child : fallback,
      ),
    );
  }
}

class CouponCodePill extends StatelessWidget {
  const CouponCodePill({super.key, required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      label: context.l10n.couponsCodeSemantics(code),
      child: Container(
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
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
          ),
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
    final l10n = context.l10n;
    final now = DateTime.now();
    final until = offer.validUntil;
    final soon = offer.expiresSoon(now);
    final color = soon ? c.warning : c.textMuted;
    final String label;
    if (until == null) {
      label = l10n.couponsOpenEnded;
    } else {
      final days = until.difference(now).inDays;
      label = days <= 0
          ? l10n.couponsExpiresToday
          : l10n.couponsExpiresInDays(days);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        label,
        style:
            AppTypography.caption(color).copyWith(fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// Opens the detail sheet and records a session-deduped `detail_view`.
Future<void> showCouponDetailsSheet(
  BuildContext context,
  WidgetRef ref,
  CouponOffer offer,
) {
  unawaited(ref.read(couponAnalyticsProvider).recordDetailView(offer.id));
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => navySheetTheme(CouponDetailsSheet(offer: offer)),
  );
}

class CouponDetailsSheet extends ConsumerWidget {
  const CouponDetailsSheet({super.key, required this.offer});

  final CouponOffer offer;

  /// Re-checks eligibility at the moment of the action: a cached offer can
  /// expire while the sheet is open, and a stale entry must never redeem.
  bool _stillRedeemable() => offer.isLiveAt(DateTime.now());

  Future<void> _copyCode(BuildContext context, WidgetRef ref) async {
    final l10n = context.l10n;
    if (!_stillRedeemable()) {
      showTopInfo(context, l10n.couponsOfferUnavailable);
      return;
    }
    final code = offer.code;
    if (code == null) return;
    await Clipboard.setData(ClipboardData(text: code));
    await HapticFeedback.selectionClick();
    if (context.mounted) {
      // Announced to screen readers as well as shown.
      SemanticsService.announce(
          l10n.couponsCodeCopied(code), TextDirection.rtl);
      showTopInfo(context, l10n.couponsCodeCopied(code));
    }
    // Analytics run AFTER the copy already succeeded and are never awaited:
    // a failure can never block or undo the user's action.
    unawaited(ref.read(couponAnalyticsProvider).recordCodeCopy(offer.id));
  }

  Future<void> _openPartner(BuildContext context, WidgetRef ref) async {
    final l10n = context.l10n;
    if (!_stillRedeemable()) {
      showTopInfo(context, l10n.couponsOfferUnavailable);
      return;
    }
    final raw = offer.partnerUrl;
    // Defence in depth: only https is ever launched, whatever the cache holds.
    final uri = raw == null ? null : Uri.tryParse(raw);
    if (uri == null || uri.scheme != 'https' || !uri.hasAuthority) {
      showTopInfo(context, l10n.couponsOpenFailed);
      return;
    }
    // `cta_click` counts a deliberate CLICK, not a redemption or a conversion —
    // the merchant side is never observed. It is recorded for the explicit
    // press even if the OS then fails to open the link.
    unawaited(ref.read(couponAnalyticsProvider).recordCtaClick(offer.id));
    var launched = false;
    try {
      launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      launched = false;
    }
    if (!launched && context.mounted) {
      showTopInfo(context, l10n.couponsOpenFailed);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final l10n = context.l10n;
    final english = Localizations.localeOf(context).languageCode == 'en';
    final isCode = offer.redemptionType == CouponRedemptionType.code;

    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(AppSpacing.s3),
        padding: const EdgeInsets.all(AppSpacing.s5),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(AppRadius.sheet),
          border: Border.all(color: c.border),
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  _CouponArtwork(
                    offer: offer,
                    size: 54,
                    accent: offer.accentColor ?? c.cta,
                  ),
                  const SizedBox(width: AppSpacing.s3),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(offer.partnerName,
                            style: AppTypography.caption(c.textMuted)),
                        Text(offer.title(preferEnglish: english),
                            style: AppTypography.title(c.textPrimary)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.s4),
              Text(offer.description(preferEnglish: english),
                  style: AppTypography.callout(c.textSecondary)),
              const SizedBox(height: AppSpacing.s3),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _MetaChip(
                      label: offer.category.label(preferEnglish: english)),
                  for (final tag in offer.tags)
                    _MetaChip(label: '#${tag.label(preferEnglish: english)}'),
                ],
              ),
              const SizedBox(height: AppSpacing.s3),
              Text(
                offer.countryCodes.isEmpty
                    ? l10n.couponsAvailableGlobally
                    : l10n.couponsAvailableIn(offer.countryCodes.join('، ')),
                style: AppTypography.caption(c.textMuted),
              ),
              if (offer.termsAr != null) ...[
                const SizedBox(height: AppSpacing.s3),
                Text(l10n.couponsTerms,
                    style: AppTypography.caption(c.textMuted)
                        .copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(offer.termsAr!,
                    style: AppTypography.footnote(c.textSecondary)),
              ],
              const SizedBox(height: AppSpacing.s4),
              if (isCode && offer.code != null) ...[
                CouponCodePill(code: offer.code!),
                const SizedBox(height: AppSpacing.s3),
                FilledButton.icon(
                  onPressed: () => _copyCode(context, ref),
                  icon: const Icon(AppLucideIcons.copy),
                  label: Text(l10n.couponsCopyCode),
                ),
                if (offer.partnerUrl != null) ...[
                  const SizedBox(height: AppSpacing.s2),
                  OutlinedButton.icon(
                    onPressed: () => _openPartner(context, ref),
                    icon: const Icon(AppLucideIcons.externalLink),
                    label: Text(l10n.couponsOpenPartner),
                  ),
                ],
              ] else
                FilledButton.icon(
                  onPressed: () => _openPartner(context, ref),
                  icon: const Icon(AppLucideIcons.externalLink),
                  label: Text(l10n.couponsUseOffer),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.surfaceCard,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: c.border),
      ),
      child: Text(label, style: AppTypography.caption(c.textMuted)),
    );
  }
}
