import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/finance/money.dart';
import '../../core/utils/l10n_ext.dart';
import '../../domain/finance/money_input.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/category_glyph.dart';
import '../../core/utils/category_tone.dart';
import '../../core/theme/widgets/navy_sheet_theme.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/id_generator.dart';
import '../../domain/entities/account_entity.dart';
import '../../domain/entities/budget_entity.dart';
import '../../domain/entities/goal_entity.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../../core/theme/widgets/app_toast.dart';
import '../common/repo_error_messages.dart';
import '../common/app_sheet_scaffold.dart';
import '../common/category_catalog.dart';
import '../dashboard/dashboard_providers.dart';
import '../goals/goals_providers.dart';
import 'budgets_providers.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/theme/widgets/glass_dropdown_field.dart';

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
      builder: (_) => navySheetTheme(const AllocateIncomeSheet._()),
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

  // Display and suggestion only. Save parses complete inputs into Money below;
  // these doubles never decide which financial rows are written.
  double _displayAmount(String text) {
    try {
      return double.tryParse(normalizeLocalizedDecimal(text)) ?? 0;
    } on Exception {
      return 0;
    }
  }

  double _income() => _displayAmount(_incomeController.text);
  double _val(String key) => _displayAmount(_ctrl(key).text);
  double _savings() => _displayAmount(_savingsController.text);
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
    try {
      final currency = ref.read(baseCurrencyProvider).valueOrNull ?? 'SAR';
      final amounts = <String, Money>{};
      try {
        for (final key in _allocationPlan.keys) {
          final text = _ctrl(key).text.trim();
          if (text.isNotEmpty) amounts[key] = parseLocalizedMoney(text, currency);
        }
      } on Exception {
        if (mounted) AppToast.showError(context, context.l10n.gfEnterValidAmount);
        return;
      }

      // Read and validate the selected goal's own-currency input before an
      // envelope write or old roll-up deletion can occur.
      GoalEntity? savingsGoal;
      Money? savingsMoney;
      final goalId = _savingsGoalId;
      final savingsText = _savingsController.text.trim();
      if (goalId != null && savingsText.isNotEmpty) {
        savingsGoal = await ref.read(goalRepositoryProvider).getById(goalId);
        if (savingsGoal != null) {
          try {
            savingsMoney = parseLocalizedMoney(savingsText, savingsGoal.currency);
          } on Exception {
            if (mounted) AppToast.showError(context, context.l10n.gfEnterValidAmount);
            return;
          }
        }
      }

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
      // §25 — new budgets are seeded from the effective base currency; amounts are
      // parsed EXACTLY from each envelope's input string.
      for (final entry in _allocationPlan.entries) {
        final amount = amounts[entry.key];
        final category = catalog.byKey(entry.key);
        if (amount == null || amount.minorUnits <= 0 || category == null) continue;
        await save(
          BudgetEntity(
            id: idFor(category.id) ?? IdGenerator.next(),
            categoryId: category.id,
            currency: currency,
            amountMoney: amount,
            lastNotifiedSpentMoney: Money(0, currency),
            period: BudgetPeriod.monthly,
            startDate: now,
            isActive: true,
            lastNotifiedPeriodStart: now,
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
      if (savingsMoney != null && savingsMoney.minorUnits > 0 && savingsGoal != null) {
        await ref.read(goalRepositoryProvider).save(
          savingsGoal.copyWith(
            autoSaveMoney: savingsMoney,
            autoSavePeriod: 'monthly',
            autoSaveLastRun: savingsGoal.autoSaveLastRun ?? now,
          ),
        );
      }

      if (!mounted) return;
      refreshBudgets(ref);
      ref.invalidate(dashboardDataProvider);
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      AppToast.showError(context, error is RepoException
          ? repoErrorMessage(context, error) : context.l10n.bfSaveFailed);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final catalog = ref.watch(categoryCatalogProvider).valueOrNull;
    final currency = Currency.label(context, 
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
      title: context.l10n.aiTitle,
      subtitle: context.l10n.aiSubtitle,
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
        child: Text(_saving ? context.l10n.aiSaving : context.l10n.aiSaveSplit),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _incomeController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: context.l10n.aiMonthlyIncome,
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
              icon: const Icon(AppLucideIcons.sparkles, size: 16),
              label: Text(context.l10n.aiSuggestSplit),
            ),
          ),
          const SizedBox(height: AppSpacing.s2),
          if (catalog == null)
            const Center(
                child: Padding(
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
                        // `.catgrid .c .icobox` — a 36px tile at radius 12,
                        // on the category's wash rather than its full colour.
                        color: categoryTone(category.iconName, Theme.of(context).brightness).background,
                        borderRadius: BorderRadius.circular(AppRadius.md),
                      ),
                      child: CategoryGlyph(
                        name: category.iconName,
                        size: 18,
                        color: categoryTone(category.iconName, Theme.of(context).brightness).ink,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.s3),
                    Expanded(
                      child: Text(category.name,
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
                    Icon(AppLucideIcons.piggyBank, color: c.success, size: 20),
                    const SizedBox(width: AppSpacing.s2),
                    Expanded(
                      child: Text(context.l10n.aiSavings,
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
                      context.l10n.aiCreateGoalHint,
                      style: AppTypography.caption(c.textLight),
                    )
                  else
                    GlassDropdownField<String>(
                      value: _savingsGoalId,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: context.l10n.aiAutoToGoal,
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
                _summaryRow(c, context.l10n.aiAllocated,
                    '${Formatters.amount(allocated)} $currency'),
                const SizedBox(height: 6),
                _summaryRow(
                    c, context.l10n.aiSavings, '${Formatters.amount(savings)} $currency',
                    tone: c.success),
                const SizedBox(height: 6),
                _summaryRow(
                  c,
                  leftover >= 0 ? context.l10n.aiUnallocated : context.l10n.aiOverIncomeBy,
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
        Text(value, style: AppTypography.bodyStrong(tone ?? c.textMain)),
      ],
    );
  }
}
