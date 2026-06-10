import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/id_generator.dart';
import '../../domain/entities/budget_entity.dart';
import '../common/category_catalog.dart';
import 'budgets_providers.dart';

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
    return _BudgetFormContent(budgetId: widget.budgetId, fullScreen: true);
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
      child: Material(
        color: c.bg,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppRadius.cardLg),
        ),
        child: Container(
        height: MediaQuery.of(context).size.height * 0.88,
        decoration: BoxDecoration(
          color: c.bg,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppRadius.cardLg),
          ),
          border: Border.all(color: c.primary.withValues(alpha: 0.22)),
        ),
        child: Column(
          children: [
            const SizedBox(height: AppSpacing.s3),
            Container(
              width: 44,
              height: 5,
              decoration: BoxDecoration(
                color: c.border,
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.gutter,
                AppSpacing.s4,
                AppSpacing.gutter,
                AppSpacing.s2,
              ),
              child: Row(
                children: [
                  Text(
                    budgetId == null ? 'ميزانية جديدة' : 'تعديل الميزانية',
                    style: AppTypography.title2(c.textMain),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
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
    final budgetAsync = widget.budgetId == null
        ? const AsyncValue<BudgetEntity?>.data(null)
        : ref.watch(budgetByIdProvider(widget.budgetId!));
    final categoriesAsync = ref.watch(categoryCatalogProvider);

    final body = budgetAsync.when(
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
                  padding: const EdgeInsets.all(AppSpacing.gutter),
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
                      decoration: const InputDecoration(labelText: 'التصنيف'),
                      validator: (value) =>
                          value == null ? 'اختر تصنيفًا' : null,
                    ),
                    const SizedBox(height: AppSpacing.s4),
                    TextFormField(
                      controller: _amountController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'المبلغ',
                        suffixText: 'ريال',
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
                    SwitchListTile(
                      value: _alert80,
                      onChanged: (value) => setState(() => _alert80 = value),
                      title: const Text('نبّهني عند 80%'),
                    ),
                    SwitchListTile(
                      value: _alert100,
                      onChanged: (value) => setState(() => _alert100 = value),
                      title: const Text('نبّهني عند 100%'),
                    ),
                    const SizedBox(height: AppSpacing.s6),
                    FilledButton(
                      onPressed: () => _submit(context, budget),
                      child: const Text('حفظ الميزانية'),
                    ),
                    if (budget != null) ...[
                      const SizedBox(height: AppSpacing.s3),
                      OutlinedButton(
                        onPressed: () => _confirmDelete(context, budget.id),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: context.colors.danger,
                          side: BorderSide(color: context.colors.danger),
                        ),
                        child: const Text('حذف الميزانية'),
                      ),
                    ],
                  ],
                ),
              );
            },
          );
        },
      );

    if (!widget.fullScreen) {
      return body;
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.budgetId == null ? 'ميزانية جديدة' : 'تعديل الميزانية'),
      ),
      body: body,
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('حذف الميزانية؟'),
        content: const Text('سيتم حذف هذه الميزانية نهائياً.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('حذف'),
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
    return SegmentedButton<BudgetPeriod>(
      segments: const [
        ButtonSegment(value: BudgetPeriod.daily, label: Text('يومي')),
        ButtonSegment(value: BudgetPeriod.weekly, label: Text('أسبوعي')),
        ButtonSegment(value: BudgetPeriod.monthly, label: Text('شهري')),
      ],
      selected: {value},
      style: ButtonStyle(
        textStyle: WidgetStatePropertyAll(AppTypography.subhead(c.textMain)),
      ),
      onSelectionChanged: (selection) => onChanged(selection.first),
    );
  }
}
