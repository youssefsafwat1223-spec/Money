import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/l10n_ext.dart';
import '../common/widgets.dart';
import 'coupon_models.dart';
import 'coupon_widgets.dart';
import 'coupons_providers.dart';

/// COUPONS Phase 1 — every live offer for one canonical merchant.
///
/// Reads only from the local cache, like the Offers screen. The merchant id in
/// the route is a CATALOG id, not the device-local `merchants.id`: local ids are
/// normalization-derived and differ between users, so one could never be shared
/// in a link or a notification.
///
/// A direct open is always safe. If the flag is off, the merchant is unknown, or
/// it has no live offers, the screen resolves to a calm empty state — it never
/// invents content and never errors at the user.
class MerchantOffersScreen extends ConsumerWidget {
  const MerchantOffersScreen({super.key, required this.merchantId});

  final String merchantId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final c = context.colors;
    final english = Localizations.localeOf(context).languageCode == 'en';

    final merchants = ref.watch(catalogMerchantsProvider).valueOrNull;
    final grouped = ref.watch(couponsByMerchantProvider);
    final merchant = merchants?[merchantId];

    // The merchant's own name when the catalog knows it. Falling back to the
    // offer's partner_name rather than showing an id keeps the page readable
    // even if the merchant row is mid-sync.
    final title = merchant == null
        ? null
        : (english && (merchant.nameEn?.trim().isNotEmpty ?? false)
            ? merchant.nameEn!
            : merchant.nameAr);

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
                    title == null
                        ? l10n.couponsStoresSection
                        : l10n.couponsMerchantOffers(title),
                    style: AppTypography.calmTitle(c.textPrimary)
                        .copyWith(fontSize: 22, letterSpacing: -0.5),
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
      body: grouped.when(
        skipLoadingOnReload: true,
        loading: () => AppLoadingState(label: l10n.couponsLoading),
        error: (_, __) => AppErrorState(
          title: l10n.couponsErrorTitle,
          description: l10n.couponsErrorBody,
          retryLabel: l10n.couponsRetry,
          onRetry: () => ref.invalidate(cachedCouponsProvider),
        ),
        data: (byMerchant) {
          final offers = byMerchant[merchantId] ?? const <CouponOffer>[];
          if (offers.isEmpty) {
            return AppEmptyState(
              icon: AppLucideIcons.tag,
              title: l10n.couponsMerchantEmptyTitle,
              subtitle: l10n.couponsMerchantEmptyBody,
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutter,
              AppSpacing.s2,
              AppSpacing.gutter,
              AppSpacing.s6,
            ),
            itemCount: offers.length,
            separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.s3),
            itemBuilder: (context, i) => CouponCard(offer: offers[i]),
          );
        },
      ),
    );
  }
}
