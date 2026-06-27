import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../domain/entities/plan_entity.dart';
import '../../domain/entities/transaction_entity.dart';
import '../common/app_card.dart';
import '../common/app_empty_state.dart';
import '../common/app_header.dart';
import '../common/app_screen_scaffold.dart';
import '../common/app_sheet_scaffold.dart';
import '../dashboard/dashboard_providers.dart';
import '../transactions/transaction_details_screen.dart';
import 'plan_form_sheet.dart';
import 'plans_providers.dart';

class PlansScreen extends ConsumerWidget {
  const PlansScreen({super.key});

  static Future<void> open(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const PlansScreen()),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final async = ref.watch(plansWithSpentProvider);
    return AppScreenScaffold(
      header: AppHeader(
        title: 'الخطط',
        subtitle: 'ميزانية لكل مناسبة، بتتابع نفسها',
        showBack: true,
        action: IconButton(
          tooltip: 'خطة جديدة',
          onPressed: () => PlanFormSheet.show(context),
          icon: Icon(AppLucideIcons.plus, color: c.cta),
        ),
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('تعذّر التحميل: $e')),
        data: (plans) {
          if (plans.isEmpty) {
            return Center(
              child: SingleChildScrollView(
                padding:
                    const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
                child: AppEmptyState(
                  icon: Icons.luggage_rounded,
                  title: 'لا توجد خطط بعد',
                  subtitle:
                      'أنشئ خطة لرحلة أو مناسبة: ميزانية + فترة + الكروت اللي هتصرف منها، وقرش يتابعها لك.',
                  primaryLabel: 'خطة جديدة',
                  onPrimary: () => PlanFormSheet.show(context),
                ),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.gutter, AppSpacing.s4, AppSpacing.gutter, 120),
            children: [
              for (final progress in plans) ...[
                _PlanCard(progress: progress),
                const SizedBox(height: AppSpacing.s4),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _PlanCard extends ConsumerWidget {
  const _PlanCard({required this.progress});

  final PlanProgress progress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final plan = progress.plan;
    final currency = Currency.arabicLabel(plan.currency);
    final barColor = progress.isOver
        ? c.danger
        : (progress.ratio >= 0.8 ? c.warning : c.success);

    return AppCard(
      onTap: () => _PlanDetailsSheet.show(context, plan.id),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  gradient: c.primaryGradient,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: const Icon(Icons.luggage_rounded,
                    color: Colors.white, size: 22),
              ),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(plan.name,
                        style: AppTypography.bodyStrong(c.textMain),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    Text(
                      '${Formatters.fullDate(plan.startDate, context)} - ${Formatters.fullDate(plan.endDate, context)}',
                      style: AppTypography.caption(c.textLight),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'حذف',
                icon: Icon(Icons.delete_outline, color: c.textLight, size: 20),
                onPressed: () => _confirmDelete(context, ref),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s3),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${Formatters.amount(progress.spent)} $currency',
                style: AppTypography.title2(c.textMain)
                    .copyWith(fontWeight: FontWeight.w900),
              ),
              const SizedBox(width: 6),
              Text('من ${Formatters.amount(plan.budgetAmount)} $currency',
                  style: AppTypography.caption(c.textLight)),
            ],
          ),
          const SizedBox(height: AppSpacing.s2),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: LinearProgressIndicator(
              value: progress.ratio,
              minHeight: 9,
              backgroundColor: c.surface2,
              valueColor: AlwaysStoppedAnimation(barColor),
            ),
          ),
          const SizedBox(height: AppSpacing.s2),
          Row(
            children: [
              Expanded(
                child: Text(
                  progress.isOver
                      ? 'تجاوزت الميزانية بـ ${Formatters.amount(-progress.remaining)} $currency'
                      : 'باقي ${Formatters.amount(progress.remaining)} $currency',
                  style: AppTypography.caption(
                      progress.isOver ? c.danger : c.textSecondary),
                ),
              ),
              if (plan.daysLeft > 0 && !progress.isOver)
                Text(
                  '${Formatters.amount(progress.perDayLeft)} $currency/يوم · ${plan.daysLeft} يوم',
                  style: AppTypography.caption(c.textLight),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف الخطة؟'),
        content: Text(
            'هتتشال خطة «${progress.plan.name}». العمليات نفسها مش هتتأثر.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('إلغاء')),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('حذف')),
        ],
      ),
    );
    if (ok != true) return;
    if (!context.mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    await ref.read(planRepositoryProvider).delete(progress.plan.id);
    ref.invalidate(plansWithSpentProvider);
    ref.invalidate(planProgressProvider(progress.plan.id));
    ref.invalidate(planTransactionsProvider(progress.plan.id));
    ref.invalidate(dashboardDataProvider);
    if (context.mounted) Navigator.of(context).pop();
  }
}

class _PlanDetailsSheet extends ConsumerWidget {
  const _PlanDetailsSheet({required this.planId});

  final String planId;

  static Future<void> show(BuildContext context, String planId) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _PlanDetailsSheet(planId: planId),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progressAsync = ref.watch(planProgressProvider(planId));
    final txAsync = ref.watch(planTransactionsProvider(planId));
    final c = context.colors;
    return progressAsync.when(
      loading: () => const AppSheetScaffold(
        title: 'تفاصيل الخطة',
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => AppSheetScaffold(
        title: 'تفاصيل الخطة',
        body: Center(child: Text('تعذّر التحميل: $e')),
      ),
      data: (progress) {
        if (progress == null) {
          return const AppSheetScaffold(
            title: 'تفاصيل الخطة',
            body: Center(child: Text('الخطة غير موجودة')),
          );
        }
        final plan = progress.plan;
        final currency = Currency.arabicLabel(plan.currency);
        return AppSheetScaffold(
          title: plan.name,
          subtitle:
              '${Formatters.fullDate(plan.startDate, context)} - ${Formatters.fullDate(plan.endDate, context)}',
          scrollable: true,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
          bottomAction: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => PlanFormSheet.show(context, existing: plan),
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('تعديل'),
                ),
              ),
              const SizedBox(width: AppSpacing.s2),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => _showLinkTransactionSheet(
                    context,
                    ref,
                    plan,
                    txAsync.valueOrNull ?? const [],
                  ),
                  icon: const Icon(Icons.add_link_rounded),
                  label: const Text('ربط عملية'),
                ),
              ),
            ],
          ),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${Formatters.amount(progress.spent)} $currency',
                      style: AppTypography.title1(c.textMain)
                          .copyWith(fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'من ${Formatters.amount(plan.budgetAmount)} $currency',
                      style: AppTypography.caption(c.textLight),
                    ),
                    const SizedBox(height: AppSpacing.s3),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                      child: LinearProgressIndicator(
                        value: progress.ratio,
                        minHeight: 9,
                        backgroundColor: c.surface2,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.s4),
              Text('سجل الخطة', style: AppTypography.title2(c.textMain)),
              const SizedBox(height: AppSpacing.s2),
              txAsync.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Text('تعذّر تحميل العمليات: $e'),
                data: (transactions) {
                  if (transactions.isEmpty) {
                    return AppEmptyState(
                      icon: Icons.receipt_long_outlined,
                      title: 'لا توجد عمليات مرتبطة',
                      subtitle: 'اربط عملية موجودة أو اختار حساب/كارت للخطة.',
                      primaryLabel: 'ربط عملية',
                      onPrimary: () => _showLinkTransactionSheet(
                        context,
                        ref,
                        plan,
                        transactions,
                      ),
                    );
                  }
                  return Column(
                    children: [
                      for (final tx in transactions)
                        _PlanTransactionTile(
                          tx: tx,
                          onTap: () => TransactionDetailsScreen.showSheet(
                              context, tx.id),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

class _PlanTransactionTile extends StatelessWidget {
  const _PlanTransactionTile({required this.tx, required this.onTap});

  final TransactionEntity tx;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppCard(
      onTap: onTap,
      margin: const EdgeInsets.only(bottom: AppSpacing.s2),
      padding: const EdgeInsets.all(AppSpacing.s3),
      child: Row(
        children: [
          Icon(Icons.receipt_long_outlined, color: c.cta),
          const SizedBox(width: AppSpacing.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tx.rawMerchant?.trim().isNotEmpty == true
                      ? tx.rawMerchant!
                      : 'عملية',
                  style: AppTypography.bodyStrong(c.textMain),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  Formatters.fullDate(tx.occurredAt, context),
                  style: AppTypography.caption(c.textLight),
                ),
              ],
            ),
          ),
          Text(
            '${Formatters.amount(tx.amount)} ${Currency.arabicLabel(tx.currency)}',
            style: AppTypography.bodyStrong(c.danger),
          ),
        ],
      ),
    );
  }
}

Future<void> _showLinkTransactionSheet(
  BuildContext context,
  WidgetRef ref,
  PlanEntity plan,
  List<TransactionEntity> linkedTransactions,
) {
  final linkedIds = linkedTransactions.map((tx) => tx.id).toSet();
  String? linkingId;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => StatefulBuilder(
      builder: (context, setState) {
        final c = context.colors;
        return AppSheetScaffold(
          title: 'ربط عملية بالخطة',
          subtitle: plan.name,
          scrollable: true,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
          body: FutureBuilder<List<TransactionEntity>>(
            future: ref.read(transactionRepositoryProvider).getAll(),
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final transactions = snapshot.data!
                  .where((tx) =>
                      !linkedIds.contains(tx.id) &&
                      tx.status == TransactionStatus.confirmed &&
                      (tx.type == TransactionTypeEntity.payment ||
                          tx.type == TransactionTypeEntity.withdrawal))
                  .take(40)
                  .toList(growable: false);
              if (transactions.isEmpty) {
                return const AppEmptyState(
                  icon: Icons.link_off_rounded,
                  title: 'لا توجد عمليات مناسبة',
                  subtitle: 'كل العمليات المناسبة مرتبطة بالفعل أو غير مؤكدة.',
                );
              }
              return Column(
                children: [
                  for (final tx in transactions)
                    AppCard(
                      margin: const EdgeInsets.only(bottom: AppSpacing.s2),
                      padding: const EdgeInsets.all(AppSpacing.s3),
                      onTap: linkingId == null
                          ? () async {
                              setState(() => linkingId = tx.id);
                              await ref
                                  .read(planRepositoryProvider)
                                  .linkTransactionToPlan(
                                    planId: plan.id,
                                    transactionId: tx.id,
                                  );
                              ref.invalidate(plansWithSpentProvider);
                              ref.invalidate(planProgressProvider(plan.id));
                              ref.invalidate(planTransactionsProvider(plan.id));
                              ref.invalidate(dashboardDataProvider);
                              if (context.mounted) Navigator.of(context).pop();
                            }
                          : null,
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              tx.rawMerchant?.trim().isNotEmpty == true
                                  ? tx.rawMerchant!
                                  : Formatters.fullDate(tx.occurredAt, context),
                              style: AppTypography.bodyStrong(c.textMain),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (linkingId == tx.id)
                            const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          else
                            Text(
                              '${Formatters.amount(tx.amount)} ${Currency.arabicLabel(tx.currency)}',
                              style: AppTypography.caption(c.textSecondary),
                            ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        );
      },
    ),
  );
}
