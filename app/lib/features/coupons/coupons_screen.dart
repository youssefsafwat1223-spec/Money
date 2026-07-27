import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../common/widgets.dart';
import 'coupon_widgets.dart';
import 'coupons_providers.dart';

class CouponsScreen extends ConsumerWidget {
  const CouponsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coupons = ref.watch(couponsProvider);
    final c = context.colors;
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
                    'الكوبونات',
                    // Mockup `.tophead .h1`: 24px w600, tight tracking.
                    style: AppTypography.calmTitle(c.textPrimary)
                        .copyWith(fontSize: 24, letterSpacing: -0.5),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'عروض شركاء تساعدك توفر في مصروفاتك اليومية.',
                    // Mockup `.hsub`: 13px secondary.
                    style: AppTypography.caption(c.textSecondary)
                        .copyWith(fontSize: 13, fontWeight: FontWeight.w400),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
      ),
      body: coupons.when(
        skipLoadingOnReload: true,
        loading: () => const AppLoadingState(label: 'تحميل العروض...'),
        error: (_, __) => AppErrorState(
          title: 'تعذر تحميل الكوبونات',
          description: 'حاول مرة أخرى بعد لحظات.',
          retryLabel: 'إعادة المحاولة',
          onRetry: () => ref.invalidate(couponsProvider),
        ),
        data: (offers) {
          if (offers.isEmpty) {
            return const AppEmptyState(
              icon: Icons.local_offer_outlined,
              title: 'لا توجد كوبونات حالياً',
              subtitle: 'هنعرض لك عروض الشركاء هنا أول ما تكون متاحة.',
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutter,
              AppSpacing.s2,
              AppSpacing.gutter,
              120,
            ),
            itemCount: offers.length,
            separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.s3),
            itemBuilder: (context, index) => CouponCard(offer: offers[index]),
          );
        },
      ),
    );
  }
}
