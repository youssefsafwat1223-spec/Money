import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/id_generator.dart';
import '../../domain/entities/goal_entity.dart';
import '../budgets/budgets_providers.dart';
import '../dashboard/dashboard_providers.dart';
import 'goals_providers.dart';

TextStyle _alex(double size, FontWeight weight, double height, Color color,
    {bool tabular = false, List<Shadow>? shadows}) {
  return GoogleFonts.inter(
    fontSize: size,
    fontWeight: weight,
    height: height,
    color: color,
    shadows: shadows,
    fontFeatures: tabular ? const [FontFeature.tabularFigures()] : null,
  ).copyWith(
    fontFamilyFallback: [
      GoogleFonts.ibmPlexSansArabic().fontFamily!,
      GoogleFonts.alexandria().fontFamily!,
    ],
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
      builder: (_) => _GoalFormSheet(goal: goal),
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
  DateTime? _deadline;
  bool _seeded = false;

  @override
  void dispose() {
    _nameController.dispose();
    _amountController.dispose();
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
          const SizedBox(height: AppSpacing.s6),
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
                onPressed: _submit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.transparent,
                  shadowColor: Colors.transparent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: Text(
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
    if (!_formKey.currentState!.validate()) {
      return;
    }
    await ref.read(saveGoalUseCaseProvider).call(
          (widget.goal ??
                  GoalEntity(
                    id: IdGenerator.next(),
                    name: _nameController.text.trim(),
                    targetAmount: double.parse(_amountController.text),
                    savedAmount: 0,
                    deadline: _deadline?.toUtc(),
                    vaultSkin: 'default_vault',
                    status: 'active',
                    createdAt: DateTime.now().toUtc(),
                  ))
              .copyWith(
            name: _nameController.text.trim(),
            targetAmount: double.parse(_amountController.text),
            deadline: _deadline?.toUtc(),
          ),
        );
    if (!mounted) {
      return;
    }
    refreshGoals(ref);
    refreshBudgets(ref);
    ref.invalidate(dashboardDataProvider);
    if (widget.goal != null) {
      ref.invalidate(goalDetailsProvider(widget.goal!.id));
    }
    Navigator.of(context).pop();
  }
}
