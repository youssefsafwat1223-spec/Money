import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../domain/finance/money.dart';
import '../../domain/finance/money_input.dart';
import '../../domain/entities/account_entity.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/mali_glass.dart';
import '../../core/theme/widgets/navy_sheet_theme.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/id_generator.dart';
import '../../domain/entities/budget_entity.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../common/app_button.dart';
import '../common/category_catalog.dart';
import 'budgets_providers.dart';
import '../../core/theme/widgets/app_toast.dart';
import '../common/app_header.dart';
import '../../core/utils/app_lucide_icons.dart';

TextStyle _alex(double size, FontWeight weight, double height, Color color,
    {bool tabular = false, List<Shadow>? shadows}) {
  return AppTypography.custom(
    size: size,
    weight: weight,
    height: height,
    color: color,
    shadows: shadows,
    tabular: tabular,
  );
}

class BudgetFormScreen extends ConsumerStatefulWidget {
  const BudgetFormScreen({super.key, this.budgetId});

  final String? budgetId;

  static Future<void> showSheet(BuildContext context, {String? budgetId}) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => navySheetTheme(_BudgetFormSheet(budgetId: budgetId)),
    );
  }

  @override
  ConsumerState<BudgetFormScreen> createState() => _BudgetFormScreenState();
}

class _BudgetFormScreenState extends ConsumerState<BudgetFormScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppHeader(
        title: widget.budgetId == null ? 'ميزانية جديدة' : 'تعديل الميزانية',
      ),
      body: _BudgetFormContent(budgetId: widget.budgetId, fullScreen: true),
    );
  }
}

class _BudgetFormSheet extends StatelessWidget {
  const _BudgetFormSheet({this.budgetId});

  final String? budgetId;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: MaliGlass(
          variant: MaliGlassVariant.sheet,
          child: SizedBox(
            height: MediaQuery.of(context).size.height * 0.85,
            child: Column(
              children: [
                const SizedBox(height: 12),
                Container(
                  width: 44,
                  height: 5,
                  decoration: BoxDecoration(
                    color: c.textLight.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                  child: Row(
                    children: [
                      Text(
                        budgetId == null ? 'ميزانية جديدة' : 'تعديل الميزانية',
                        style: AppTypography.title2(c.textMain),
                      ),
                      const Spacer(),
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: Icon(AppLucideIcons.x, color: c.textMain),
                        style: IconButton.styleFrom(
                          backgroundColor: c.surface.withValues(alpha: 0.4),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child:
                      _BudgetFormContent(budgetId: budgetId, fullScreen: false),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BudgetFormContent extends ConsumerStatefulWidget {
  const _BudgetFormContent({
    required this.fullScreen,
    this.budgetId,
  });

  final String? budgetId;
  final bool fullScreen;

  @override
  ConsumerState<_BudgetFormContent> createState() => _BudgetFormContentState();
}

class _BudgetFormContentState extends ConsumerState<_BudgetFormContent> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  BudgetPeriod _period = BudgetPeriod.monthly;
  String? _categoryId;
  String? _accountId;
  bool _didSeedInitialState = false;
  bool _suggestionLoading = false;
  bool _saving = false;
  Money? _suggestedAmount;
  String? _suggestionKey;

  @override
  void dispose() {
    _amountController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final budgetAsync = widget.budgetId == null
        ? const AsyncValue<BudgetEntity?>.data(null)
        : ref.watch(budgetByIdProvider(widget.budgetId!));
    final categoriesAsync = ref.watch(categoryCatalogProvider);
    final accounts =
        ref.watch(accountsProvider).valueOrNull ?? <AccountEntity>[];
    final selectedAccount = _selectedAccount(accounts);
    final baseCurrency = ref.watch(baseCurrencyProvider).valueOrNull ?? 'SAR';
    final currencyLabel =
        Currency.arabicLabel(selectedAccount?.currency ?? baseCurrency);

    return budgetAsync.when(
      skipLoadingOnReload: true,
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => const Center(child: Text('حدث خطأ')),
      data: (budget) {
        return categoriesAsync.when(
          skipLoadingOnReload: true,
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => const Center(child: Text('حدث خطأ')),
          data: (catalog) {
            _seedInitialState(budget);
            return Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.gutter, vertical: 8),
                children: [
                  DropdownButtonFormField<String>(
                    value: _categoryId,
                    items: [
                      const DropdownMenuItem<String>(
                        value: BudgetEntity.allExpensesCategoryId,
                        child: Text('كل المصروفات'),
                      ),
                      for (final category in catalog.all.where(
                        (it) =>
                            it.key != 'income' &&
                            it.key != BudgetEntity.allExpensesCategoryKey,
                      ))
                        DropdownMenuItem<String>(
                          value: category.id,
                          child: Text(category.nameAr),
                        ),
                    ],
                    onChanged: (value) {
                      setState(() => _categoryId = value);
                      _refreshSuggestedAmount();
                    },
                    style: _alex(14, FontWeight.w700, 1.2, c.textMain),
                    decoration: InputDecoration(
                      labelText: 'التصنيف',
                      labelStyle: _alex(13, FontWeight.w700, 1.2, c.textLight),
                      filled: true,
                      fillColor: c.surface.withValues(alpha: 0.15),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 14),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide:
                            BorderSide(color: c.border.withValues(alpha: 0.3)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide:
                            BorderSide(color: c.border.withValues(alpha: 0.3)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide(color: c.primary, width: 1.5),
                      ),
                    ),
                    validator: (value) => value == null ? 'اختر تصنيفًا' : null,
                  ),
                  const SizedBox(height: AppSpacing.s4),
                  TextFormField(
                    controller: _amountController,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    style: _alex(15, FontWeight.w700, 1.2, c.textMain),
                    decoration: InputDecoration(
                      labelText: 'المبلغ',
                      labelStyle: _alex(13, FontWeight.w700, 1.2, c.textLight),
                      suffixText: currencyLabel,
                      suffixStyle: _alex(14, FontWeight.w700, 1.2, c.textMain),
                      filled: true,
                      fillColor: c.surface.withValues(alpha: 0.15),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 14),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide:
                            BorderSide(color: c.border.withValues(alpha: 0.3)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide:
                            BorderSide(color: c.border.withValues(alpha: 0.3)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide(color: c.primary, width: 1.5),
                      ),
                    ),
                    validator: (value) {
                      final amount = double.tryParse(value ?? '');
                      if (amount == null || amount <= 0) {
                        return 'أدخل مبلغًا صحيحًا';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: AppSpacing.s4),
                  _PeriodSelector(
                    value: _period,
                    onChanged: (value) {
                      setState(() => _period = value);
                      _refreshSuggestedAmount();
                    },
                  ),
                  if (accounts.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.s4),
                    DropdownButtonFormField<String>(
                      value: selectedAccount?.id,
                      style: _alex(14, FontWeight.w700, 1.2, c.textMain),
                      decoration: InputDecoration(
                        labelText: 'الحساب',
                        labelStyle:
                            _alex(13, FontWeight.w700, 1.2, c.textLight),
                        filled: true,
                        fillColor: c.surface.withValues(alpha: 0.15),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 14),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide(
                              color: c.border.withValues(alpha: 0.3)),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide(
                              color: c.border.withValues(alpha: 0.3)),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide(color: c.primary, width: 1.5),
                        ),
                      ),
                      items: [
                        for (final acc in accounts)
                          DropdownMenuItem<String>(
                            value: acc.id,
                            child: Text(acc.name),
                          ),
                      ],
                      onChanged: (v) {
                        setState(() => _accountId = v);
                        _refreshSuggestedAmount();
                      },
                    ),
                  ],
                  if (budget == null) ...[
                    const SizedBox(height: AppSpacing.s3),
                    _BudgetSuggestionCard(
                      loading: _suggestionLoading,
                      amount: _suggestedAmount,
                      period: _period,
                      onApply: _suggestedAmount == null
                          ? null
                          : () => setState(() {
                                _amountController.text =
                                    _suggestedAmount!.toDecimalString();
                              }),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.s4),
                  const SizedBox(height: AppSpacing.s5),
                  // زر النظام الأسود (ink) — بدل التدرّج الأزرق القديم.
                  AppPrimaryButton(
                    label: 'حفظ الميزانية',
                    onTap: () => _submit(budget),
                    loading: _saving,
                    height: 52,
                  ),
                  if (budget != null) ...[
                    const SizedBox(height: AppSpacing.s3),
                    SizedBox(
                      height: 52,
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: () => _confirmDelete(context, budget.id),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: c.danger,
                          side: BorderSide(color: c.danger, width: 1.5),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: Text(
                          'حذف الميزانية',
                          style: _alex(15, FontWeight.w700, 1.2, c.danger),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _submit(BudgetEntity? existing) async {
    if (_saving || !_formKey.currentState!.validate() || _categoryId == null) {
      return;
    }
    setState(() => _saving = true);
    try {
      // §25 — an existing budget keeps its persisted currency; a new one is
      // seeded from the effective base. The amount is parsed EXACTLY from the
      // input string into that currency (never double -> Money.fromLegacyReal).
      final currency = existing?.currency ??
          (ref.read(baseCurrencyProvider).valueOrNull ?? 'SAR');
      final amountMoney = parseLocalizedMoney(_amountController.text, currency);
      final accounts =
          ref.read(accountsProvider).valueOrNull ?? <AccountEntity>[];
      final selectedAccount = _selectedAccount(accounts);
      final navigator = Navigator.of(context);
      final budget = (existing ??
              BudgetEntity(
                id: IdGenerator.next(),
                categoryId: _categoryId!,
                currency: currency,
                amountMoney: amountMoney,
                lastNotifiedSpentMoney: Money(0, currency),
                period: _period,
                startDate: DateTime.now().toUtc(),
                isActive: true,
                lastNotifiedPeriodStart: DateTime.now().toUtc(),
              ))
          .copyWith(
        categoryId: _categoryId,
        amountMoney: amountMoney,
        period: _period,
        showOnHeader: false,
        accountId: selectedAccount?.id,
      );
      await ref.read(saveBudgetUseCaseProvider).call(budget);
      if (!mounted) return;
      refreshBudgets(ref);
      navigator.pop();
    } catch (error) {
      if (!mounted) return;
      final message = error is RepoException
          ? repoExceptionMessage(error)
          : 'حدث خطأ غير متوقع أثناء الحفظ. حاول مجددًا.';
      AppToast.show(context, message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _confirmDelete(BuildContext context, String budgetId) async {
    final c = context.colors;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: c.surface,
        title: Text('حذف الميزانية؟',
            style: _alex(18, FontWeight.w700, 1.2, c.textMain)),
        content: Text('سيتم حذف هذه الميزانية نهائياً.',
            style: _alex(14, FontWeight.w500, 1.4, c.textLight)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('إلغاء',
                style: _alex(14, FontWeight.w700, 1.2, c.textLight)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: c.danger),
            child: Text('حذف',
                style: _alex(14, FontWeight.w700, 1.2, Colors.white)),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) {
      return;
    }
    final navigator = Navigator.of(context);
    await ref.read(deleteBudgetUseCaseProvider).call(budgetId);
    if (!mounted) {
      return;
    }
    refreshBudgets(ref);
    navigator.pop();
  }

  void _seedInitialState(BudgetEntity? budget) {
    if (_didSeedInitialState) {
      return;
    }
    _didSeedInitialState = true;
    if (budget == null) {
      _categoryId = BudgetEntity.allExpensesCategoryId;
      Future.microtask(_refreshSuggestedAmount);
      return;
    }
    // Seed from the CANONICAL money, not the display double: `_save()` parses
    // this text straight back into Money, so any rounding here silently
    // rewrites the stored amount on an untouched Save (1500.50 → 1501).
    _amountController.text = budget.amountMoney.toDecimalString();
    _period = budget.period;
    _categoryId = budget.categoryId;
    _categoryId = budget.categoryId;
    _accountId = budget.accountId;
  }

  AccountEntity? _selectedAccount(List<AccountEntity> accounts) {
    if (accounts.isEmpty) return null;
    final selectedId = _accountId;
    if (selectedId != null) {
      for (final account in accounts) {
        if (account.id == selectedId) return account;
      }
    }
    return accounts.firstWhere(
      (account) => account.isDefault,
      orElse: () => accounts.first,
    );
  }

  Future<void> _refreshSuggestedAmount() async {
    final categoryId = _categoryId;
    if (categoryId == null || widget.budgetId != null) return;
    final accounts =
        ref.read(accountsProvider).valueOrNull ?? <AccountEntity>[];
    final selectedAccount = _selectedAccount(accounts);
    final accountId = selectedAccount?.id;
    final currency = selectedAccount?.currency ??
        (ref.read(baseCurrencyProvider).valueOrNull ?? 'SAR');
    final key =
        '$categoryId:${_period.name}:$accountId:${currency.toUpperCase()}';
    if (_suggestionKey == key && _suggestedAmount != null) return;
    setState(() {
      _suggestionKey = key;
      _suggestionLoading = true;
      _suggestedAmount = null;
    });
    final now = DateTime.now();
    final from = DateTime(now.year, now.month, now.day)
        .subtract(const Duration(days: 29));
    final txRepo = ref.read(transactionRepositoryProvider);
    final total = categoryId == BudgetEntity.allExpensesCategoryId
        ? await txRepo.expenseTotalBetween(
            from: from,
            to: now,
            currency: currency,
            accountId: accountId,
          )
        : await txRepo.categoryExpenseTotalBetween(
            categoryId: categoryId,
            from: from,
            to: now,
            currency: currency,
            accountId: accountId,
          );
    if (!mounted || _suggestionKey != key) return;
    final amount = switch (_period) {
      BudgetPeriod.daily => total.applyRate(
          rateNumerator: BigInt.one,
          rateDenominator: BigInt.from(30),
        ),
      BudgetPeriod.weekly => total.applyRate(
          rateNumerator: BigInt.from(7),
          rateDenominator: BigInt.from(30),
        ),
      BudgetPeriod.monthly => total,
      BudgetPeriod.yearly => total.applyRate(
          rateNumerator: BigInt.from(365),
          rateDenominator: BigInt.from(30),
        ),
    };
    final zero = Money.zero(currency);
    setState(() {
      _suggestionLoading = false;
      _suggestedAmount =
          amount.compareTo(zero) <= 0 ? null : _roundBudgetSuggestion(amount);
    });
  }

  Money _roundBudgetSuggestion(Money amount) {
    final stepMajor = amount.compareTo(Money.parse('50', amount.currency)) < 0
        ? 1
        : amount.compareTo(Money.parse('500', amount.currency)) < 0
            ? 10
            : 50;
    final scaleFactor =
        switch (amount.scale) { 0 => 1, 2 => 100, 3 => 1000, _ => 1 };
    final stepMinor = stepMajor * scaleFactor;
    final roundedMinor =
        ((amount.minorUnits + stepMinor - 1) ~/ stepMinor) * stepMinor;
    return Money(roundedMinor, amount.currency);
  }
}

class _BudgetSuggestionCard extends StatelessWidget {
  const _BudgetSuggestionCard({
    required this.loading,
    required this.amount,
    required this.period,
    required this.onApply,
  });

  final bool loading;
  final Money? amount;
  final BudgetPeriod period;
  final VoidCallback? onApply;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final label = switch (period) {
      BudgetPeriod.daily => 'يومية',
      BudgetPeriod.weekly => 'أسبوعية',
      BudgetPeriod.monthly => 'شهرية',
      BudgetPeriod.yearly => 'سنوية',
    };
    final value = amount?.toDecimalString();
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s3),
      decoration: BoxDecoration(
        color: c.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.primary.withValues(alpha: 0.16)),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: c.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(13),
            ),
            child: loading
                ? const Padding(
                    padding: EdgeInsets.all(10),
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(AppLucideIcons.sparkles, color: c.primary),
          ),
          const SizedBox(width: AppSpacing.s3),
          Expanded(
            child: Text(
              loading
                  ? 'بنحسب اقتراح من آخر 30 يوم...'
                  : value == null
                      ? 'بعد ما تضيف عمليات أكثر، هنقترح ميزانية $label مناسبة.'
                      : 'اقتراح ميزانية $label: $value',
              style: _alex(12, FontWeight.w700, 1.35, c.textMain),
            ),
          ),
          if (value != null) ...[
            const SizedBox(width: AppSpacing.s2),
            TextButton(
              onPressed: onApply,
              child: const Text('استخدمه'),
            ),
          ],
        ],
      ),
    );
  }
}

class _PeriodSelector extends StatelessWidget {
  const _PeriodSelector({
    required this.value,
    required this.onChanged,
  });

  final BudgetPeriod value;
  final ValueChanged<BudgetPeriod> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'دورية الميزانية',
          style: _alex(12, FontWeight.w700, 1.2, c.textLight),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: c.surface.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: c.border.withValues(alpha: 0.3)),
          ),
          child: Row(
            children: [
              _buildSegment(context, BudgetPeriod.daily, 'يومي'),
              _buildSegment(context, BudgetPeriod.weekly, 'أسبوعي'),
              _buildSegment(context, BudgetPeriod.monthly, 'شهري'),
              _buildSegment(context, BudgetPeriod.yearly, 'سنوي'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSegment(
      BuildContext context, BudgetPeriod period, String label) {
    final c = context.colors;
    final active = value == period;
    return Expanded(
      child: GestureDetector(
        onTap: () => onChanged(period),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: active ? c.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            boxShadow: active
                ? [
                    BoxShadow(
                      color: c.primary.withValues(alpha: 0.2),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: _alex(13, active ? FontWeight.bold : FontWeight.w600, 1.2,
                active ? Colors.white : c.textLight),
          ),
        ),
      ),
    );
  }
}
