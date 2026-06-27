import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/id_generator.dart';
import '../../domain/entities/account_entity.dart';
import '../../domain/entities/budget_entity.dart';
import '../common/app_sheet_scaffold.dart';
import '../common/category_catalog.dart';
import '../dashboard/dashboard_providers.dart';
import '../goals/goals_providers.dart';
import 'budgets_providers.dart';

/// Suggested monthly split by category (stable keys). Sums to ~67%, leaving the
/// rest as savings/buffer. Just a starting point — the user edits freely.
const _allocationPlan = <String, double>{
  'groceries': 0.15,
  'bills': 0.12,
  'restaurants': 0.10,
  'transport': 0.08,
  'shopping': 0.08,
  'health': 0.05,
  'subscriptions': 0.04,
  'entertainment': 0.05,
};

/// «وزّع دخلك» — تكتب دخلك، التطبيق يقترح توزيعه على التصنيفات كمظاريف
/// (ميزانيات شهرية)، وإجمالي الخطة بيغذّي «المتاح للصرف النهاردة».
class AllocateIncomeSheet extends ConsumerStatefulWidget {
  const AllocateIncomeSheet._();

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const AllocateIncomeSheet._(),
    );
  }

  @override
  ConsumerState<AllocateIncomeSheet> createState() =>
      _AllocateIncomeSheetState();
}

class _AllocateIncomeSheetState extends ConsumerState<AllocateIncomeSheet> {
  final _incomeController = TextEditingController();
  final _savingsController = TextEditingController();
  final Map<String, TextEditingController> _controllers = {};
  String? _savingsGoalId;
  bool _saving = false;

  /// Suggested savings share of income (the rest of the 50/30/20 idea).
  static const _savingsShare = 0.20;

  TextEditingController _ctrl(String key) =>
      _controllers.putIfAbsent(key, () => TextEditingController());

  @override
  void dispose() {
    _incomeController.dispose();
    _savingsController.dispose();
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  double _income() => double.tryParse(_incomeController.text.trim()) ?? 0;
  double _val(String key) => double.tryParse(_ctrl(key).text.trim()) ?? 0;
  double _savings() => double.tryParse(_savingsController.text.trim()) ?? 0;
  double _allocated() =>
      _allocationPlan.keys.fold<double>(0, (sum, k) => sum + _val(k));

  void _suggest() {
    final income = _income();
    if (income <= 0) return;
    setState(() {
      for (final entry in _allocationPlan.entries) {
        _ctrl(entry.key).text = (income * entry.value).toStringAsFixed(0);
      }
      _savingsController.text = (income * _savingsShare).toStringAsFixed(0);
    });
  }

  Future<void> _save(CategoryCatalog catalog) async {
    if (_saving) return;
    setState(() => _saving = true);

    final selectedId = ref.read(dashboardAccountProvider);
    final accountRepo = ref.read(accountRepositoryProvider);
    AccountEntity? account =
        selectedId == null ? null : await accountRepo.getById(selectedId);
    account ??= await accountRepo.getDefault();
    final accountId = account?.id;

    final existing = await ref.read(budgetRepositoryProvider).getAll();
    String? idFor(String categoryId) {
      for (final budget in existing) {
        if (budget.categoryId == categoryId &&
            budget.period == BudgetPeriod.monthly &&
            budget.accountId == accountId) {
          return budget.id;
        }
      }
      return null;
    }

    final save = ref.read(saveBudgetUseCaseProvider);
    final budgetRepo = ref.read(budgetRepositoryProvider);
    final now = DateTime.now().toUtc();
    for (final entry in _allocationPlan.entries) {
      final amount = _val(entry.key);
      final category = catalog.byKey(entry.key);
      if (amount <= 0 || category == null) continue;
      await save(
        BudgetEntity(
          id: idFor(category.id) ?? IdGenerator.next(),
          categoryId: category.id,
          amount: amount,
          period: BudgetPeriod.monthly,
          startDate: now,
          isActive: true,
          alert80Sent: false,
          alert100Sent: false,
          accountId: accountId,
        ),
      );
    }

    // The envelopes ARE the plan; the total is computed as their sum everywhere.
    // Remove any stale "all expenses" roll-up budget for this account so the
    // total is never counted twice.
    for (final budget in existing) {
      if (budget.isAllExpenses && budget.accountId == accountId) {
        await budgetRepo.delete(budget.id);
      }
    }

    // Route the chosen savings amount to a goal as a monthly auto-save, so the
    // money actually accumulates toward it (via the goal auto-save engine).
    final savings = _savings();
    final goalId = _savingsGoalId;
    if (savings > 0 && goalId != null) {
      final goalRepo = ref.read(goalRepositoryProvider);
      final goal = await goalRepo.getById(goalId);
      if (goal != null) {
        await goalRepo.save(
          goal.copyWith(
            autoSaveAmount: savings,
            autoSavePeriod: 'monthly',
            autoSaveLastRun: goal.autoSaveLastRun ?? now,
          ),
        );
      }
    }

    if (!mounted) return;
    refreshBudgets(ref);
    ref.invalidate(dashboardDataProvider);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final catalog = ref.watch(categoryCatalogProvider).valueOrNull;
    final currency = Currency.arabicLabel(
      ref.watch(baseCurrencyProvider).valueOrNull ?? 'SAR',
    );
    final income = _income();
    final allocated = _allocated();
    final savings = _savings();
    final leftover = income - allocated - savings;
    final goals = (ref.watch(goalsListProvider).valueOrNull ?? const [])
        .where((g) => g.status == 'active')
        .toList();

    final categories = [
      for (final key in _allocationPlan.keys)
        if (catalog?.byKey(key) != null) catalog!.byKey(key)!,
    ];

    return AppSheetScaffold(
      title: 'وزّع دخلك',
      subtitle: 'اكتب دخلك، ووزّعه على المظاريف — تقدر تعدّل أي رقم.',
      scrollable: true,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
      bottomAction: FilledButton(
        onPressed: (catalog == null || allocated <= 0 || _saving)
            ? null
            : () => _save(catalog),
        style: FilledButton.styleFrom(
          backgroundColor: c.cta,
          foregroundColor: c.onCta,
          minimumSize: const Size.fromHeight(52),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        child: Text(_saving ? 'جارٍ الحفظ...' : 'احفظ التوزيع'),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _incomeController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'دخلك الشهري',
              suffixText: currency,
              filled: true,
              fillColor: c.surface2.withValues(alpha: 0.5),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide(color: c.border),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.s2),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: income > 0 ? _suggest : null,
              icon: const Icon(Icons.auto_awesome, size: 16),
              label: const Text('اقترح توزيع تلقائي'),
            ),
          ),
          const SizedBox(height: AppSpacing.s2),
          if (catalog == null)
            const Center(child: Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(),
            ))
          else
            for (final category in categories) ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: category.color.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(11),
                      ),
                      child:
                          Icon(category.icon, color: category.color, size: 18),
                    ),
                    const SizedBox(width: AppSpacing.s3),
                    Expanded(
                      child: Text(category.nameAr,
                          style: AppTypography.subhead(c.textMain)),
                    ),
                    SizedBox(
                      width: 110,
                      child: TextField(
                        controller: _ctrl(category.key),
                        textAlign: TextAlign.center,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: '0',
                          suffixText: currency,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 10),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: c.border),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          const SizedBox(height: AppSpacing.s4),
          // ── الادخار (قابل للتخصيص) ─────────────────────────────────
          Container(
            padding: const EdgeInsets.all(AppSpacing.s3),
            decoration: BoxDecoration(
              color: c.success.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: c.success.withValues(alpha: 0.25)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.savings_rounded, color: c.success, size: 20),
                    const SizedBox(width: AppSpacing.s2),
                    Expanded(
                      child: Text('الادخار',
                          style: AppTypography.subhead(c.textMain)),
                    ),
                    SizedBox(
                      width: 110,
                      child: TextField(
                        controller: _savingsController,
                        textAlign: TextAlign.center,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: '0',
                          suffixText: currency,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 10),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: c.border),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                if (savings > 0) ...[
                  const SizedBox(height: AppSpacing.s2),
                  if (goals.isEmpty)
                    Text(
                      'أنشئ هدف ادخار عشان نحوّلهالك تلقائياً كل شهر.',
                      style: AppTypography.caption(c.textLight),
                    )
                  else
                    DropdownButtonFormField<String>(
                      value: _savingsGoalId,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: 'يتحوّل تلقائياً لهدف',
                        isDense: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: c.border),
                        ),
                      ),
                      items: [
                        for (final goal in goals)
                          DropdownMenuItem(
                              value: goal.id, child: Text(goal.name)),
                      ],
                      onChanged: (v) => setState(() => _savingsGoalId = v),
                    ),
                ],
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.s3),
          Container(
            padding: const EdgeInsets.all(AppSpacing.s3),
            decoration: BoxDecoration(
              color: c.surface2.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: c.border),
            ),
            child: Column(
              children: [
                _summaryRow(c, 'موزّع على المظاريف',
                    '${Formatters.amount(allocated)} $currency'),
                const SizedBox(height: 6),
                _summaryRow(c, 'الادخار',
                    '${Formatters.amount(savings)} $currency',
                    tone: c.success),
                const SizedBox(height: 6),
                _summaryRow(
                  c,
                  leftover >= 0 ? 'متبقي غير موزّع' : 'تجاوزت دخلك بـ',
                  '${Formatters.amount(leftover.abs())} $currency',
                  tone: leftover >= 0 ? c.textMain : c.danger,
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.s3),
        ],
      ),
    );
  }

  Widget _summaryRow(AppColors c, String label, String value, {Color? tone}) {
    return Row(
      children: [
        Expanded(
          child: Text(label, style: AppTypography.caption(c.textLight)),
        ),
        Text(value,
            style: AppTypography.bodyStrong(tone ?? c.textMain)),
      ],
    );
  }
}
