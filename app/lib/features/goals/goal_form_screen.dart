import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/navy_sheet_theme.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/id_generator.dart';
import '../../domain/entities/goal_entity.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../budgets/budgets_providers.dart';
import '../dashboard/dashboard_providers.dart';
import 'goals_providers.dart';
import '../../core/theme/widgets/app_toast.dart';

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

class GoalFormScreen extends ConsumerStatefulWidget {
  const GoalFormScreen({super.key, this.goal});

  final GoalEntity? goal;

  static Future<void> showSheet(BuildContext context, {GoalEntity? goal}) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => navySheetTheme(_GoalFormSheet(goal: goal)),
    );
  }

  @override
  ConsumerState<GoalFormScreen> createState() => _GoalFormScreenState();
}

class _GoalFormScreenState extends ConsumerState<GoalFormScreen> {
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text(widget.goal == null ? 'هدف جديد' : 'تعديل الهدف'),
        ),
        body: _GoalFormContent(
          fullScreen: true,
          goal: widget.goal,
        ),
      );
}

class _GoalFormSheet extends StatelessWidget {
  const _GoalFormSheet({this.goal});

  final GoalEntity? goal;

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
            height: MediaQuery.of(context).size.height * 0.82,
            decoration: BoxDecoration(
              color: isDark
                  ? c.surface.withValues(alpha: 0.9)
                  : Colors.white.withValues(alpha: 0.92),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(28)),
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
                        goal == null ? 'هدف جديد' : 'تعديل الهدف',
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
                  child: _GoalFormContent(fullScreen: false, goal: goal),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GoalFormContent extends ConsumerStatefulWidget {
  const _GoalFormContent({
    required this.fullScreen,
    this.goal,
  });

  final bool fullScreen;
  final GoalEntity? goal;

  @override
  ConsumerState<_GoalFormContent> createState() => _GoalFormContentState();
}

class _GoalFormContentState extends ConsumerState<_GoalFormContent> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _amountController = TextEditingController();
  final _autoSaveController = TextEditingController();
  DateTime? _deadline;
  bool _autoSaveOn = false;
  String _autoSavePeriod = 'monthly';
  bool _seeded = false;
  bool _saving = false;

  @override
  void dispose() {
    _nameController.dispose();
    _amountController.dispose();
    _autoSaveController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    _seedInitialState();
    final recommended = _recommendedDailyAmount();
    final cur = Currency.arabicLabel(
        ref.watch(baseCurrencyProvider).valueOrNull ?? 'SAR');
    return Form(
      key: _formKey,
      child: ListView(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.gutter,
          widget.fullScreen ? AppSpacing.gutter : AppSpacing.s2,
          AppSpacing.gutter,
          MediaQuery.of(context).viewInsets.bottom + AppSpacing.s6,
        ),
        children: [
          TextFormField(
            controller: _nameController,
            style: _alex(15, FontWeight.w700, 1.2, c.textMain),
            decoration: InputDecoration(
              labelText: 'اسم الهدف',
              labelStyle: _alex(13, FontWeight.w700, 1.2, c.textLight),
              filled: true,
              fillColor: c.surface.withValues(alpha: 0.15),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
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
            validator: (value) => (value == null || value.trim().isEmpty)
                ? 'اكتب اسم الهدف'
                : null,
          ),
          const SizedBox(height: AppSpacing.s4),
          TextFormField(
            controller: _amountController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: _alex(15, FontWeight.w700, 1.2, c.textMain),
            decoration: InputDecoration(
              labelText: 'المبلغ المستهدف',
              labelStyle: _alex(13, FontWeight.w700, 1.2, c.textLight),
              suffixText: cur,
              suffixStyle: _alex(14, FontWeight.w800, 1.2, c.textMain),
              filled: true,
              fillColor: c.surface.withValues(alpha: 0.15),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
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
            onChanged: (_) => setState(() {}),
            validator: (value) {
              final amount = double.tryParse(value ?? '');
              if (amount == null || amount <= 0) {
                return 'أدخل مبلغًا صحيحًا';
              }
              return null;
            },
          ),
          const SizedBox(height: AppSpacing.s4),
          Container(
            decoration: BoxDecoration(
              color: c.surface.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: c.border.withValues(alpha: 0.3)),
            ),
            child: Material(
              type: MaterialType.transparency,
              child: ListTile(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                title: Text('الموعد النهائي',
                    style: _alex(14, FontWeight.w700, 1.2, c.textMain)),
                subtitle: Text(
                  _deadline == null
                      ? 'اختياري'
                      : Formatters.fullDate(_deadline!, context),
                  style: _alex(12, FontWeight.w500, 1.2, c.textLight),
                ),
                trailing: Icon(Icons.calendar_today_outlined,
                    color: c.textLight, size: 20),
                onTap: _pickDeadline,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.s4),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: (recommended == null ? c.primary : c.success)
                  .withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                  color: (recommended == null ? c.primary : c.success)
                      .withValues(alpha: 0.2)),
            ),
            child: Row(
              children: [
                Icon(
                  recommended == null
                      ? Icons.info_outline_rounded
                      : Icons.lightbulb_outline_rounded,
                  color: recommended == null ? c.primary : c.success,
                  size: 18,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    recommended == null
                        ? 'المبلغ الموصى به يظهر بعد اختيار التاريخ.'
                        : 'المبلغ الموصى به: ${Formatters.integer(recommended)} $cur يوميًا لـ ${((_deadline!.difference(DateTime.now()).inDays))} يوم.',
                    style: _alex(12, FontWeight.w700, 1.4,
                        recommended == null ? c.textLight : c.success),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.s5),
          Container(
            padding: const EdgeInsets.all(AppSpacing.s4),
            decoration: BoxDecoration(
              color: c.surface.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: c.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('ادخار تلقائي',
                              style:
                                  _alex(14, FontWeight.w800, 1.2, c.textMain)),
                          const SizedBox(height: 2),
                          Text('قرش يضيف المبلغ للهدف كل فترة تلقائياً',
                              style:
                                  _alex(11, FontWeight.w600, 1.3, c.textLight)),
                        ],
                      ),
                    ),
                    Switch(
                      value: _autoSaveOn,
                      onChanged: (v) => setState(() => _autoSaveOn = v),
                    ),
                  ],
                ),
                if (_autoSaveOn) ...[
                  const SizedBox(height: AppSpacing.s3),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _autoSaveController,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: InputDecoration(
                            labelText: 'المبلغ',
                            suffixText: cur,
                            isDense: true,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(color: c.border),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.s3),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          value: _autoSavePeriod,
                          isDense: true,
                          decoration: InputDecoration(
                            labelText: 'التكرار',
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(color: c.border),
                            ),
                          ),
                          items: const [
                            DropdownMenuItem(
                                value: 'weekly', child: Text('أسبوعي')),
                            DropdownMenuItem(
                                value: 'monthly', child: Text('شهري')),
                          ],
                          onChanged: (v) =>
                              setState(() => _autoSavePeriod = v ?? 'monthly'),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
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
                onPressed: _saving ? null : _submit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.transparent,
                  shadowColor: Colors.transparent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: _saving
                    ? const SizedBox.square(
                        dimension: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Text(
                        widget.goal == null ? 'أنشئ الهدف' : 'حفظ التعديل',
                        style: _alex(15, FontWeight.w800, 1.2, Colors.white),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _seedInitialState() {
    final goal = widget.goal;
    if (_seeded || goal == null) {
      return;
    }
    _nameController.text = goal.name;
    _amountController.text = goal.targetAmount.toStringAsFixed(0);
    _deadline = goal.deadline?.toLocal();
    if (goal.hasAutoSave) {
      _autoSaveOn = true;
      _autoSaveController.text = goal.autoSaveAmount!.toStringAsFixed(0);
      _autoSavePeriod = goal.autoSavePeriod ?? 'monthly';
    }
    _seeded = true;
  }

  double? _recommendedDailyAmount() {
    final amount = double.tryParse(_amountController.text);
    if (amount == null || amount <= 0 || _deadline == null) {
      return null;
    }
    final days = _deadline!.difference(DateTime.now()).inDays;
    if (days <= 0) {
      return amount;
    }
    return amount / days;
  }

  Future<void> _pickDeadline() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now().add(const Duration(days: 90)),
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 3650)),
      locale: const Locale('ar'),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: Theme.of(context).colorScheme.copyWith(
                  primary: context.colors.primary,
                ),
          ),
          child: child!,
        );
      },
    );
    if (picked != null) {
      setState(() => _deadline = picked);
    }
  }

  Future<void> _submit() async {
    if (_saving || !_formKey.currentState!.validate()) {
      return;
    }
    final deadline = _deadline;
    if (deadline != null) {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final deadlineDate = DateTime(
        deadline.year,
        deadline.month,
        deadline.day,
      );
      if (deadlineDate.isBefore(today)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('اختار موعدًا نهائيًا قادمًا أو اليوم.')),
        );
        return;
      }
    }
    setState(() => _saving = true);
    try {
      final accountId = widget.goal?.accountId ?? await _resolveAccountId();
      final base = widget.goal;
      final autoAmount = double.tryParse(_autoSaveController.text.trim()) ?? 0;
      final autoOn = _autoSaveOn && autoAmount > 0;
      final goal = GoalEntity(
        id: base?.id ?? IdGenerator.next(),
        name: _nameController.text.trim(),
        accountId: accountId,
        targetAmount: double.parse(_amountController.text),
        savedAmount: base?.savedAmount ?? 0,
        deadline: _deadline?.toUtc(),
        vaultSkin: base?.vaultSkin ?? 'default_vault',
        status: base?.status ?? 'active',
        createdAt: base?.createdAt ?? DateTime.now().toUtc(),
        autoSaveAmount: autoOn ? autoAmount : null,
        autoSavePeriod: autoOn ? _autoSavePeriod : null,
        // Start the schedule now so catch-up doesn't backfill from creation.
        autoSaveLastRun:
            autoOn ? (base?.autoSaveLastRun ?? DateTime.now().toUtc()) : null,
      );
      await ref.read(saveGoalUseCaseProvider).call(goal);
      if (!mounted) return;
      refreshGoals(ref);
      refreshBudgets(ref);
      ref.invalidate(dashboardDataProvider);
      if (widget.goal != null) {
        ref.invalidate(goalDetailsProvider(widget.goal!.id));
      }
      Navigator.of(context).pop();
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

  Future<String?> _resolveAccountId() async {
    final accountRepo = ref.read(accountRepositoryProvider);
    final selectedId = ref.read(activeAccountIdProvider);
    if (selectedId != null) {
      final selected = await accountRepo.getById(selectedId);
      if (selected != null) {
        return selected.id;
      }
    }
    return (await accountRepo.getDefault())?.id;
  }
}
