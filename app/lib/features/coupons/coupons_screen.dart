import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/l10n_ext.dart';
import '../common/widgets.dart';
import 'coupon_models.dart';
import 'coupon_widgets.dart';
import 'coupons_providers.dart';
import '../../core/utils/app_lucide_icons.dart';

/// MALI-COUPONS (Phase C4) — the Offers screen, backed by the real catalog.
///
/// Reads ONLY from the local cache (architecture rule 1); the network is the
/// catalog sync's job. When the feature flag is off it resolves to a calm empty
/// state instead of promotional UI, so a direct route open is always safe.
class CouponsScreen extends ConsumerStatefulWidget {
  const CouponsScreen({super.key, this.highlightSlug});

  /// `/coupons?highlight={slug}` — focuses one offer if it is ELIGIBLE.
  /// An unknown, expired or country-ineligible slug simply shows the normal
  /// screen: the deep route can never bypass eligibility.
  final String? highlightSlug;

  @override
  ConsumerState<CouponsScreen> createState() => _CouponsScreenState();
}

class _CouponsScreenState extends ConsumerState<CouponsScreen> {
  String? _categoryKey;
  String? _tagKey;
  bool _highlightHandled = false;

  void _maybeOpenHighlight(List<CouponOffer> offers) {
    final slug = widget.highlightSlug;
    if (_highlightHandled || slug == null || slug.isEmpty) return;
    _highlightHandled = true;
    // Only an ELIGIBLE offer can be highlighted — `offers` is already filtered.
    final match = offers.where((o) => o.slug == slug).firstOrNull;
    if (match == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) showCouponDetailsSheet(context, ref, match);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final c = context.colors;
    final english = Localizations.localeOf(context).languageCode == 'en';
    final coupons = ref.watch(couponsProvider);
    final categories =
        ref.watch(couponCategoriesProvider).valueOrNull ?? const [];
    final tags = ref.watch(couponTagsProvider).valueOrNull ?? const [];

    return AppScreenScaffold(
      header: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter,
          AppSpacing.s3,
          AppSpacing.gutter,
          AppSpacing.s2,
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.couponsTitle,
                    style: AppTypography.calmTitle(c.textPrimary)
                        .copyWith(fontSize: 24, letterSpacing: -0.5),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l10n.couponsSubtitle,
                    style: AppTypography.caption(c.textSecondary)
                        .copyWith(fontSize: 13, fontWeight: FontWeight.w400),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(AppLucideIcons.x),
            ),
          ],
        ),
      ),
      body: coupons.when(
        skipLoadingOnReload: true,
        loading: () => AppLoadingState(label: l10n.couponsLoading),
        error: (_, __) => AppErrorState(
          title: l10n.couponsErrorTitle,
          description: l10n.couponsErrorBody,
          retryLabel: l10n.couponsRetry,
          onRetry: () => ref.invalidate(cachedCouponsProvider),
        ),
        data: (offers) {
          _maybeOpenHighlight(offers);
          if (offers.isEmpty) {
            return AppEmptyState(
              icon: AppLucideIcons.tag,
              title: l10n.couponsEmptyTitle,
              subtitle: l10n.couponsEmptyBody,
            );
          }

          final filtered = offers.where((o) {
            if (_categoryKey != null && o.category.key != _categoryKey) {
              return false;
            }
            if (_tagKey != null && !o.tags.any((t) => t.key == _tagKey)) {
              return false;
            }
            return true;
          }).toList(growable: false);

          final featured =
              filtered.where((o) => o.featured).toList(growable: false);
          final rest =
              filtered.where((o) => !o.featured).toList(growable: false);

          return ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutter,
              AppSpacing.s2,
              AppSpacing.gutter,
              120,
            ),
            children: [
              _FilterRow(
                label: l10n.couponsFilterAll,
                selectedCategory: _categoryKey,
                selectedTag: _tagKey,
                categories: categories,
                tags: tags,
                english: english,
                onCategory: (key) => setState(() => _categoryKey = key),
                onTag: (key) => setState(() => _tagKey = key),
              ),
              const SizedBox(height: AppSpacing.s3),
              if (filtered.isEmpty)
                AppEmptyState(
                  icon: AppLucideIcons.filterX,
                  title: l10n.couponsFilterEmptyTitle,
                  subtitle: l10n.couponsFilterEmptyBody,
                )
              else ...[
                if (featured.isNotEmpty) ...[
                  Text(
                    l10n.couponsFeaturedSection,
                    style: AppTypography.caption(c.textMuted)
                        .copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: AppSpacing.s2),
                  for (final offer in featured) ...[
                    CouponCard(
                      offer: offer,
                      highlighted: offer.slug == widget.highlightSlug,
                    ),
                    const SizedBox(height: AppSpacing.s3),
                  ],
                ],
                for (final offer in rest) ...[
                  CouponCard(
                    offer: offer,
                    highlighted: offer.slug == widget.highlightSlug,
                  ),
                  const SizedBox(height: AppSpacing.s3),
                ],
              ],
            ],
          );
        },
      ),
    );
  }
}

class _FilterRow extends StatelessWidget {
  const _FilterRow({
    required this.label,
    required this.selectedCategory,
    required this.selectedTag,
    required this.categories,
    required this.tags,
    required this.english,
    required this.onCategory,
    required this.onTag,
  });

  final String label;
  final String? selectedCategory;
  final String? selectedTag;
  final List<CouponCategory> categories;
  final List<CouponTag> tags;
  final bool english;
  final ValueChanged<String?> onCategory;
  final ValueChanged<String?> onTag;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          _Chip(
            label: label,
            selected: selectedCategory == null && selectedTag == null,
            onTap: () {
              onCategory(null);
              onTag(null);
            },
          ),
          for (final category in categories)
            _Chip(
              label: category.label(preferEnglish: english),
              selected: selectedCategory == category.key,
              onTap: () {
                onTag(null);
                onCategory(
                    selectedCategory == category.key ? null : category.key);
              },
            ),
          for (final tag in tags.take(8))
            _Chip(
              label: '#${tag.label(preferEnglish: english)}',
              selected: selectedTag == tag.key,
              onTap: () {
                onCategory(null);
                onTag(selectedTag == tag.key ? null : tag.key);
              },
            ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(
      {required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      selected: selected,
      button: true,
      child: Padding(
        padding: const EdgeInsets.only(left: 6),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          child: Container(
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: selected ? c.ctaSoft : c.surfaceCard,
              borderRadius: BorderRadius.circular(AppRadius.pill),
              border: Border.all(color: selected ? c.cta : c.border),
            ),
            child: Text(
              label,
              style: AppTypography.caption(selected ? c.cta : c.textSecondary)
                  .copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        ),
      ),
    );
  }
}
