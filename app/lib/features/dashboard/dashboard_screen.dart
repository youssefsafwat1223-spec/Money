import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/formatters.dart';
import '../app/app_shell.dart';
import '../common/vault_widget.dart';
import '../common/widgets.dart';
import '../transactions/transaction_details_screen.dart';
import 'dashboard_providers.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(dashboardDataProvider);
    final c = context.colors;

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(dashboardDataProvider),
      child: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ListView(
          children: [
            Padding(
                padding: const EdgeInsets.all(24), child: Text('حدث خطأ: $e'))
          ],
        ),
        data: (data) => ListView(
          padding: const EdgeInsets.only(bottom: 120),
          children: [
            // الجزء العلوي البنفسجي الممتد للحواف (Header Card)
            Container(
              width: double.infinity,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [c.gradA, c.gradB],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(32)),
                boxShadow: [
                  BoxShadow(
                    color: c.primary.withValues(alpha: 0.25),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, 16, AppSpacing.gutter, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _greeting(context, data),
                      const SizedBox(height: 20),
                      _walletSummary(context, ref, data),
                    ],
                  ),
                ),
              ),
            ),

            const SizedBox(height: AppSpacing.s5),

            // محتوى الصفحة الرئيسي مع الهوامش الجانبية
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (data.activeGoal != null) ...[
                    _goalCard(context, data),
                    const SizedBox(height: AppSpacing.s5),
                  ],

                  if (data.isEmpty)
                    _emptyState(context)
                  else ...[
                    const SizedBox(height: AppSpacing.s5),
                    _whereMoneyWent(context, data),
                    const SizedBox(height: AppSpacing.s5),
                    _recent(context, ref, data),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _greeting(BuildContext context, DashboardData data) {
    final c = context.colors;
    final hour = DateTime.now().hour;
    final greeting =
        hour < 12 ? 'صباح الخير' : (hour < 18 ? 'مساء الخير' : 'مساء الخير');
    return Row(
      children: [
        Expanded(
          child:
              Text('$greeting، يوسف', style: AppTypography.title2(Colors.white).copyWith(
                fontWeight: FontWeight.bold,
              )),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: Colors.white24,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            border: Border.all(color: Colors.white.withValues(alpha: 0.3), width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                AppLucideIcons.flame,
                size: 16,
                color: c.accent,
              ),
              const SizedBox(width: 6),
              Text(
                '${data.streak.currentStreak} يوم',
                style: AppTypography.caption(Colors.white).copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _walletSummary(BuildContext context, WidgetRef ref, DashboardData data) {
    final c = context.colors;
    final positive = data.savedThisMonth >= 0;
    final budgetSet = data.monthlyBudgetLimit > 0;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.s5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.22),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(AppRadius.pill),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('يونيو 2026',
                    style: AppTypography.subhead(Colors.white)
                        .copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(width: 6),
                const Icon(AppLucideIcons.arrowLeftRight,
                    size: 16, color: Colors.white),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.s4),
          Row(
            children: [
              Expanded(
                child: _heroMetric(
                  label: 'المصروف',
                  value: '${Formatters.amount(data.spentThisMonth)} ريال',
                ),
              ),
              Container(
                height: 48,
                width: 1,
                color: Colors.white.withValues(alpha: 0.28),
              ),
              Expanded(
                child: _heroMetric(
                  label: 'الدخل',
                  value: '${Formatters.amount(data.incomeThisMonth)} ريال',
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s4),
          InkWell(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            onTap: () => ref.read(shellIndexProvider.notifier).state = 2,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(AppRadius.pill),
                border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(AppLucideIcons.plus, color: Colors.white, size: 16),
                  const SizedBox(width: 8),
                  Text(
                    budgetSet
                        ? 'استخدمت ${(data.monthlyBudgetRatio * 100).clamp(0, 999).round()}% من ميزانية ${data.budgetPeriodLabel}'
                        : 'اضغط لضبط ميزانية كل المصروفات',
                    style: AppTypography.caption(Colors.white)
                        .copyWith(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.s4),
          Row(
            children: [
              Expanded(
                child: _glassPill(
                  icon: AppLucideIcons.wallet,
                  title: 'كل الحسابات',
                  value: data.balance == null
                      ? 'الرصيد غير معروف'
                      : '${Formatters.amount(data.balance!)} ريال',
                ),
              ),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: _glassPill(
                  icon: AppLucideIcons.arrowLeftRight,
                  title: positive ? 'وفّرت' : 'زيادة صرف',
                  value:
                      '${positive ? '+' : '−'}${Formatters.amount(data.savedThisMonth.abs())} ريال',
                  valueColor: positive ? c.success : c.accent,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _heroMetric({required String label, required String value}) {
    return Column(
      children: [
        Text(
          label,
          style: AppTypography.caption(Colors.white.withValues(alpha: 0.72))
              .copyWith(letterSpacing: 1.2, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          textAlign: TextAlign.center,
          style: AppTypography.title2(Colors.white).copyWith(
            fontWeight: FontWeight.bold,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  Widget _glassPill({
    required IconData icon,
    required String title,
    required String value,
    Color? valueColor,
  }) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
      ),
      child: Row(
        children: [
          Icon(icon, color: Colors.white, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppTypography.caption(Colors.white70)),
                const SizedBox(height: 2),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.caption(valueColor ?? Colors.white)
                      .copyWith(fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _goalCard(BuildContext context, DashboardData data) {
    final c = context.colors;
    final goal = data.activeGoal!;
    final progress =
        goal.targetAmount == 0 ? 0.0 : goal.savedAmount / goal.targetAmount;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.s5),
      decoration: BoxDecoration(
        color: c.surface.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: c.primary.withValues(alpha: 0.2), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 15,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Row(
        children: [
          // اليسار: مجسم الخزنة الزجاجية المتوهجة
          VaultWidget(progress: progress, size: 110),
          const SizedBox(width: AppSpacing.s4),
          // اليمين: معلومات الهدف بتنسيق نظيف
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: c.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: c.primary.withValues(alpha: 0.2), width: 1),
                  ),
                  child: Text(
                    'الهدف الحالي',
                    style: AppTypography.caption(c.primary).copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  goal.name,
                  style: AppTypography.title2(c.textMain).copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'المبلع الموفر:',
                  style: AppTypography.caption(c.textLight),
                ),
                const SizedBox(height: 2),
                RichText(
                  text: TextSpan(
                    children: [
                      TextSpan(
                        text: '${Formatters.integer(goal.savedAmount)} ',
                        style: AppTypography.headline(c.accent).copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      TextSpan(
                        text: 'من ${Formatters.integer(goal.targetAmount)} ريال',
                        style: AppTypography.body(c.textMain),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _whereMoneyWent(BuildContext context, DashboardData data) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('أين ذهبت أموالك؟', style: AppTypography.title2(c.textMain)),
        const SizedBox(height: AppSpacing.s3),
        for (final slice in data.topCategories) ...[
          _categoryBar(context, slice),
          const SizedBox(height: AppSpacing.s3),
        ],
      ],
    );
  }

  Widget _categoryBar(BuildContext context, CategorySlice slice) {
    final c = context.colors;
    return Row(
      children: [
        CategoryAvatar(category: slice.category, size: 38),
        const SizedBox(width: AppSpacing.s3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(slice.category.nameAr,
                        style: AppTypography.subhead(c.textMain)),
                  ),
                  Text('${(slice.percent * 100).round()}%',
                      style: AppTypography.caption(c.textLight)),
                ],
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.pill),
                child: LinearProgressIndicator(
                  value: slice.percent,
                  minHeight: 8,
                  backgroundColor: c.surface2,
                  valueColor: AlwaysStoppedAnimation(slice.category.color),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _recent(BuildContext context, WidgetRef ref, DashboardData data) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('آخر العمليات', style: AppTypography.title2(c.textMain)),
        const SizedBox(height: AppSpacing.s2),
        for (final tx in data.recent)
          TransactionRow(
            transaction: tx,
            category: data.catalog.byId(tx.categoryId),
            onTap: () => TransactionDetailsScreen.showSheet(context, tx.id),
          ),
      ],
    );
  }

  Widget _emptyState(BuildContext context) {
    final c = context.colors;
    return Container(
      margin: const EdgeInsets.only(top: AppSpacing.s5),
      padding: const EdgeInsets.all(AppSpacing.s6),
      decoration: BoxDecoration(
        color: c.surface.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: c.primary.withValues(alpha: 0.2), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 15,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: c.primary.withValues(alpha: 0.1),
              border: Border.all(color: c.primary.withValues(alpha: 0.2), width: 1.5),
            ),
            child: Icon(
              AppLucideIcons.receipt,
              size: 36,
              color: c.primary,
            ),
          ),
          const SizedBox(height: AppSpacing.s4),
          Text(
            'لا توجد عمليات مضافة',
            style: AppTypography.headline(c.textMain).copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: AppSpacing.s2),
          Text(
            'ألصق رسالة الخصم أو الإيداع التي تصلك من البنك، وسيتكفل الذكاء الاصطناعي بتصنيفها تلقائياً على جهازك.',
            textAlign: TextAlign.center,
            style: AppTypography.callout(c.textLight).copyWith(
              height: 1.5,
            ),
          ),
          const SizedBox(height: AppSpacing.s5),
          Container(
            width: double.infinity,
            height: 52,
            decoration: BoxDecoration(
              gradient: c.primaryGradient,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: c.primary.withValues(alpha: 0.35),
                  blurRadius: 14,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: ElevatedButton.icon(
              onPressed: () => context.push('/paste'),
              icon: const Icon(AppLucideIcons.clipboardPaste, color: Colors.white, size: 20),
              label: Text(
                'ألصق رسالة بنك',
                style: AppTypography.bodyStrong(Colors.white),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.transparent,
                shadowColor: Colors.transparent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

}

class SparklinePainter extends CustomPainter {
  const SparklinePainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;

    final path = Path();
    path.moveTo(0, size.height * 0.7);
    path.cubicTo(
      size.width * 0.25, size.height * 0.3,
      size.width * 0.4, size.height * 0.8,
      size.width * 0.65, size.height * 0.4,
    );
    path.cubicTo(
      size.width * 0.8, size.height * 0.2,
      size.width * 0.9, size.height * 0.6,
      size.width, size.height * 0.45,
    );

    final fillPath = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();

    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          color.withValues(alpha: 0.25),
          color.withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height))
      ..style = PaintingStyle.fill;

    canvas.drawPath(fillPath, fillPaint);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
