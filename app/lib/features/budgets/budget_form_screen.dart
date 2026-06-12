import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/id_generator.dart';
import '../../domain/entities/budget_entity.dart';
import '../common/category_catalog.dart';
import 'budgets_providers.dart';

TextStyle _alex(double size, FontWeight weight, double height, Color color, {bool tabular = false}) {
  return GoogleFonts.alexandria(
    fontSize: size,
    fontWeight: weight,
    height: height,
    color: color,
    fontFeatures: tabular ? const [FontFeature.tabularFigures()] : null,
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
      builder: (_) => _BudgetFormSheet(budgetId: budgetId),
    );
  }

  @override
  ConsumerState<BudgetFormScreen> createState() => _BudgetFormScreenState();
}

class _BudgetFormScreenState extends ConsumerState<BudgetFormScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.budgetId == null ? 'ميزانية جديدة' : 'تعديل الميزانية'),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            height: MediaQuery.of(context).size.height * 0.85,
            decoration: BoxDecoration(
              color: isDark ? c.surface.withValues(alpha: 0.9) : Colors.white.withValues(alpha: 0.92),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              border: Border.all(
                color: Colors.white.withValues(alpha: isDark ? 0.08 : 0.3),
                width: 1.5,
              ),
            ),
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
                        icon: Icon(Icons.close_rounded, color: c.textMain),
                        style: IconButton.styleFrom(
                          backgroundColor: c.surface.withValues(alpha: 0.4),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: _BudgetFormContent(budgetId: budgetId, fullScreen: false),
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
  bool _alert80 = true;
  bool _alert100 = true;

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

    return budgetAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(child: Text('حدث خطأ: $error')),
      data: (budget) {
        return categoriesAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(child: Text('حدث خطأ: $error')),
          data: (catalog) {
            _seedInitialState(budget);
            return Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter, vertical: 8),
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
                    onChanged: (value) => setState(() => _categoryId = value),
                    style: _alex(14, FontWeight.w700, 1.2, c.textMain),
                    decoration: InputDecoration(
                      labelText: 'التصنيف',
                      labelStyle: _alex(13, FontWeight.w700, 1.2, c.textLight),
                      filled: true,
                      fillColor: c.surface.withValues(alpha: 0.15),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide(color: c.border.withValues(alpha: 0.3)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide(color: c.border.withValues(alpha: 0.3)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide(color: c.primary, width: 1.5),
                      ),
                    ),
                    validator: (value) =>
                        value == null ? 'اختر تصنيفًا' : null,
                  ),
                  const SizedBox(height: AppSpacing.s4),
                  TextFormField(
                    controller: _amountController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    style: _alex(15, FontWeight.w700, 1.2, c.textMain),
                    decoration: InputDecoration(
                      labelText: 'المبلغ',
                      labelStyle: _alex(13, FontWeight.w700, 1.2, c.textLight),
                      suffixText: 'ريال',
                      suffixStyle: _alex(14, FontWeight.w800, 1.2, c.textMain),
                      filled: true,
                      fillColor: c.surface.withValues(alpha: 0.15),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide(color: c.border.withValues(alpha: 0.3)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide(color: c.border.withValues(alpha: 0.3)),
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
                    onChanged: (value) => setState(() => _period = value),
                  ),
                  const SizedBox(height: AppSpacing.s4),
                  _buildSwitchRow(
                    title: 'نبّهني عند 80%',
                    value: _alert80,
                    onChanged: (value) => setState(() => _alert80 = value),
                  ),
                  const SizedBox(height: 12),
                  _buildSwitchRow(
                    title: 'نبّهني عند 100%',
                    value: _alert100,
                    onChanged: (value) => setState(() => _alert100 = value),
                  ),
                  const SizedBox(height: AppSpacing.s5),
                  SizedBox(
                    height: 52,
                    width: double.infinity,
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: c.primaryGradient,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: c.primary.withValues(alpha: 0.25),
                            blurRadius: 15,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: ElevatedButton(
                        onPressed: () => _submit(context, budget),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.transparent,
                          shadowColor: Colors.transparent,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: Text(
                          'حفظ الميزانية',
                          style: _alex(15, FontWeight.w800, 1.2, Colors.white),
                        ),
                      ),
                    ),
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
                          style: _alex(15, FontWeight.w800, 1.2, c.danger),
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

  Widget _buildSwitchRow({
    required String title,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: c.surface.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.border.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(title, style: _alex(14, FontWeight.w700, 1.2, c.textMain)),
          Switch(
            value: value,
            onChanged: onChanged,
            activeColor: c.accent,
            activeTrackColor: c.accent.withValues(alpha: 0.3),
            inactiveThumbColor: Colors.white,
            inactiveTrackColor: c.border.withValues(alpha: 0.5),
          ),
        ],
      ),
    );
  }

  Future<void> _submit(BuildContext context, BudgetEntity? existing) async {
    if (!_formKey.currentState!.validate() || _categoryId == null) {
      return;
    }
    final amount = double.parse(_amountController.text);
    final navigator = Navigator.of(context);
    final budget = (existing ??
            BudgetEntity(
              id: IdGenerator.next(),
              categoryId: _categoryId!,
              amount: amount,
              period: _period,
              startDate: DateTime.now().toUtc(),
              isActive: true,
              alert80Sent: false,
              alert100Sent: false,
            ))
        .copyWith(
          categoryId: _categoryId,
          amount: amount,
          period: _period,
          alert80Sent: !_alert80,
          alert100Sent: !_alert100,
        );
    await ref.read(saveBudgetUseCaseProvider).call(budget);
    if (!mounted) {
      return;
    }
    refreshBudgets(ref);
    navigator.pop();
  }

  Future<void> _confirmDelete(BuildContext context, String budgetId) async {
    final c = context.colors;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: c.surface,
        title: Text('حذف الميزانية؟', style: _alex(18, FontWeight.w800, 1.2, c.textMain)),
        content: Text('سيتم حذف هذه الميزانية نهائياً.', style: _alex(14, FontWeight.w500, 1.4, c.textLight)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('إلغاء', style: _alex(14, FontWeight.w700, 1.2, c.textLight)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: c.danger),
            child: Text('حذف', style: _alex(14, FontWeight.w700, 1.2, Colors.white)),
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
    if (budget == null || _amountController.text.isNotEmpty) {
      return;
    }
    _amountController.text = budget.amount.toStringAsFixed(0);
    _period = budget.period;
    _categoryId = budget.categoryId;
    _alert80 = !budget.alert80Sent;
    _alert100 = !budget.alert100Sent;
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
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSegment(BuildContext context, BudgetPeriod period, String label) {
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
            style: _alex(13, active ? FontWeight.bold : FontWeight.w600, 1.2, active ? Colors.white : c.textLight),
          ),
        ),
      ),
    );
  }
}
