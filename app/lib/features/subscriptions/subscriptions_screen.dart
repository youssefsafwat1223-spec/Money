import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/formatters.dart';
import 'subscriptions_providers.dart';

class SubscriptionsScreen extends ConsumerWidget {
  const SubscriptionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final async = ref.watch(subscriptionsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('الاشتراكات')),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('حدث خطأ: $e')),
        data: (items) {
          if (items.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.gutter),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.repeat, size: 44, color: c.textLight),
                    const SizedBox(height: AppSpacing.s3),
                    Text('لم نكتشف اشتراكات متكررة بعد',
                        textAlign: TextAlign.center,
                        style: AppTypography.headline(c.textMain)),
                    const SizedBox(height: AppSpacing.s2),
                    Text('تظهر هنا تلقائياً عند تكرار نفس المبلغ شهرياً.',
                        textAlign: TextAlign.center,
                        style: AppTypography.callout(c.textLight)),
                  ],
                ),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.all(AppSpacing.gutter),
            children: [
              Text('اكتشفنا عمليات متكررة:',
                  style: AppTypography.subhead(c.textLight)),
              const SizedBox(height: AppSpacing.s3),
              for (final item in items)
                Container(
                  margin: const EdgeInsets.only(bottom: AppSpacing.s3),
                  padding: const EdgeInsets.all(AppSpacing.s4),
                  decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: BorderRadius.circular(AppRadius.card),
                    border: Border.all(color: c.border),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: c.primary.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(AppRadius.md),
                        ),
                        child: Icon(Icons.repeat, color: c.primary),
                      ),
                      const SizedBox(width: AppSpacing.s3),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(item.name,
                                style: AppTypography.bodyStrong(c.textMain)),
                            Text('~${Formatters.amount(item.averageAmount)} ريال/شهر · ${item.monthsSeen} أشهر',
                                style: AppTypography.caption(c.textLight)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
