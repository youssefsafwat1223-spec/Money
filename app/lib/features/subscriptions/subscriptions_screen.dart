import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/di/app_providers.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/report_models.dart';
import '../cards/brand_mark.dart';
import '../common/premium_loading.dart';
import 'subscriptions_providers.dart';

class SubscriptionsScreen extends ConsumerWidget {
  const SubscriptionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(subscriptionsProvider);
    final c = context.colors;
    final cur = Currency.arabicLabel(
        ref.watch(baseCurrencyProvider).valueOrNull ?? 'SAR');
    return async.when(
      loading: () => Scaffold(
        appBar: Navigator.of(context).canPop()
            ? AppBar(title: const Text('الاشتراكات والفواتير'))
            : null,
        body: const PremiumSkeletonPage(cardCount: 4),
      ),
      error: (e, _) => Scaffold(
        appBar: Navigator.of(context).canPop()
            ? AppBar(title: const Text('الاشتراكات والفواتير'))
            : null,
        body: Center(child: Text('حدث خطأ: $e')),
      ),
      data: (items) {
        final monthly = items.fold<double>(
          0,
          (sum, item) => sum + item.averageAmount,
        );
        return DefaultTabController(
          length: 2,
          child: Scaffold(
            body: ListView(
              padding: EdgeInsets.zero,
              children: [
                _BillsHeader(
                  monthly: monthly,
                  activeCount: items.length,
                  currency: cur,
                ),
                Padding(
                  padding: const EdgeInsets.all(AppSpacing.gutter),
                  child: Column(
                    children: [
                      Container(
                        height: 48,
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: c.surface2,
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                        ),
                        child: TabBar(
                          indicatorSize: TabBarIndicatorSize.tab,
                          dividerColor: Colors.transparent,
                          labelColor: Colors.white,
                          unselectedLabelColor: c.textLight,
                          indicator: BoxDecoration(
                            color: c.primary,
                            borderRadius: BorderRadius.circular(AppRadius.pill),
                          ),
                          tabs: const [
                            Tab(text: 'الاشتراكات'),
                            Tab(text: 'الأقساط'),
                          ],
                        ),
                      ),
                      const SizedBox(height: AppSpacing.s5),
                      SizedBox(
                        height: 470,
                        child: TabBarView(
                          children: [
                            _SubscriptionsTab(items: items, currency: cur),
                            const _InstallmentsTab(),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            floatingActionButton: FloatingActionButton.extended(
              onPressed: () => _showManualComingSoon(context),
              icon: const Icon(AppLucideIcons.plus),
              label: const Text('إضافة اشتراك'),
            ),
          ),
        );
      },
    );
  }

  void _showManualComingSoon(BuildContext context) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Directionality(
        textDirection: TextDirection.rtl,
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.gutter,
                AppSpacing.s3,
                AppSpacing.gutter,
                AppSpacing.s6,
              ),
              decoration: BoxDecoration(
                color: isDark ? c.surface.withValues(alpha: 0.9) : Colors.white.withValues(alpha: 0.92),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                border: Border.all(
                  color: Colors.white.withValues(alpha: isDark ? 0.08 : 0.3),
                  width: 1.5,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 44,
                      height: 5,
                      decoration: BoxDecoration(
                        color: c.textLight.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.s3),
                  Text('إضافة اشتراك يدوياً', style: AppTypography.title2(c.textMain)),
                  const SizedBox(height: AppSpacing.s2),
                  Text(
                    'الاكتشاف التلقائي يعمل الآن. الإضافة اليدوية ستكون الخطوة التالية مع تاريخ التجديد والتنبيه.',
                    style: AppTypography.callout(c.textLight),
                  ),
                  const SizedBox(height: AppSpacing.s4),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: FilledButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: FilledButton.styleFrom(
                        backgroundColor: c.primary,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: Text('تمام', style: AppTypography.bodyStrong(Colors.white)),
                    ),
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

class _BillsHeader extends StatelessWidget {
  const _BillsHeader({
    required this.monthly,
    required this.activeCount,
    required this.currency,
  });

  final double monthly;
  final int activeCount;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        56,
        AppSpacing.gutter,
        AppSpacing.s6,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [c.primary, c.gradB, c.success],
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
        ),
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(32)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (Navigator.of(context).canPop()) ...[
                const BackButton(color: Colors.white),
                const SizedBox(width: AppSpacing.s2),
              ],
              Expanded(
                child: Text('الاشتراكات والفواتير',
                    style: AppTypography.title1(Colors.white)
                        .copyWith(fontWeight: FontWeight.bold)),
              ),
              const _HeaderIcon(icon: AppLucideIcons.alertTriangle),
              const SizedBox(width: AppSpacing.s2),
              const _HeaderIcon(icon: AppLucideIcons.receipt),
            ],
          ),
          const SizedBox(height: AppSpacing.s5),
          Text('الصرف الشهري', style: AppTypography.subhead(Colors.white70)),
          const SizedBox(height: AppSpacing.s2),
          Text('${Formatters.amount(monthly)} $currency',
              style: AppTypography.amountHero(Colors.white)),
          const SizedBox(height: AppSpacing.s4),
          Container(
            padding: const EdgeInsets.all(AppSpacing.s4),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(AppRadius.card),
              border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
            ),
            child: Row(
              children: [
                _HeaderMetric(label: 'نشط', value: '$activeCount'),
                const _Divider(),
                _HeaderMetric(
                  label: 'سنوياً',
                  value: '${Formatters.amount(monthly * 12)} $currency',
                ),
                const _Divider(),
                const _HeaderMetric(label: 'هذا الأسبوع', value: '0'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HeaderIcon extends StatelessWidget {
  const _HeaderIcon({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.18),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, color: Colors.white, size: 20),
    );
  }
}

class _HeaderMetric extends StatelessWidget {
  const _HeaderMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(value,
              textAlign: TextAlign.center,
              style: AppTypography.bodyStrong(Colors.white)),
          const SizedBox(height: 4),
          Text(label, style: AppTypography.caption(Colors.white70)),
        ],
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 42,
      color: Colors.white.withValues(alpha: 0.20),
    );
  }
}

class _SubscriptionsTab extends StatelessWidget {
  const _SubscriptionsTab({required this.items, required this.currency});

  final List<RecurringCandidate> items;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (items.isEmpty) {
      return const _EmptyBillsState(
        icon: AppLucideIcons.repeat,
        title: 'فواتيرك تتكشف تلقائياً',
        body: 'لما تتكرر عملية بنفس المبلغ عبر أكثر من شهر، هنقترحها هنا كاشتراك.',
      );
    }
    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return Container(
          margin: const EdgeInsets.only(bottom: AppSpacing.s3),
          padding: const EdgeInsets.all(AppSpacing.s4),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(color: c.border),
          ),
          child: Row(
            children: [
              BrandMark(name: item.name, size: 48),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.name, style: AppTypography.bodyStrong(c.textMain)),
                    Text('تكرر ${item.monthsSeen} أشهر',
                        style: AppTypography.caption(c.textLight)),
                  ],
                ),
              ),
              Text('${Formatters.amount(item.averageAmount)} $currency/شهر',
                  style: AppTypography.bodyStrong(c.textMain)),
            ],
          ),
        );
      },
    );
  }
}

class _InstallmentsTab extends StatelessWidget {
  const _InstallmentsTab();

  @override
  Widget build(BuildContext context) {
    return const _EmptyBillsState(
      icon: AppLucideIcons.repeat,
      title: 'الأقساط قريباً',
      body: 'هنفصل الأقساط عن الاشتراكات ونضيف تاريخ الاستحقاق والتنبيهات.',
    );
  }
}

class _EmptyBillsState extends StatelessWidget {
  const _EmptyBillsState({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(
              color: c.primary.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(26),
            ),
            child: Icon(icon, color: c.primary, size: 34),
          ),
          const SizedBox(height: AppSpacing.s4),
          Text(title,
              textAlign: TextAlign.center,
              style:
                  AppTypography.title2(c.textMain).copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: AppSpacing.s2),
          Text(
            body,
            textAlign: TextAlign.center,
            style: AppTypography.callout(c.textLight),
          ),
        ],
      ),
    );
  }
}
