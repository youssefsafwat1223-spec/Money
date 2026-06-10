import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/id_generator.dart';
import '../../domain/entities/goal_entity.dart';
import 'goals_providers.dart';

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
  Widget build(BuildContext context) => _GoalFormContent(
        fullScreen: true,
        goal: widget.goal,
      );
}

class _GoalFormSheet extends StatelessWidget {
  const _GoalFormSheet({this.goal});

  final GoalEntity? goal;

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
        height: MediaQuery.of(context).size.height * 0.86,
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
                    goal == null ? 'هدف جديد' : 'تعديل الهدف',
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
              child: _GoalFormContent(fullScreen: false, goal: goal),
            ),
          ],
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
    _seedInitialState();
    final recommended = _recommendedDailyAmount();
    final body = Form(
      key: _formKey,
      child: ListView(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.gutter,
          widget.fullScreen ? AppSpacing.gutter : AppSpacing.s2,
          AppSpacing.gutter,
          MediaQuery.of(context).viewInsets.bottom + AppSpacing.s8,
        ),
        children: [
          TextFormField(
            controller: _nameController,
            decoration: const InputDecoration(labelText: 'اسم الهدف'),
            validator: (value) =>
                (value == null || value.trim().isEmpty) ? 'اكتب اسم الهدف' : null,
          ),
          const SizedBox(height: AppSpacing.s4),
          TextFormField(
            controller: _amountController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'المبلغ المستهدف',
              suffixText: 'ريال',
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
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('الموعد النهائي'),
            subtitle: Text(
              _deadline == null ? 'اختياري' : Formatters.fullDate(_deadline!),
            ),
            trailing: IconButton(
              onPressed: _pickDeadline,
              icon: const Icon(Icons.calendar_today_outlined),
            ),
          ),
          const SizedBox(height: AppSpacing.s3),
          Text(
            recommended == null
                ? 'المبلغ الموصى به يظهر بعد اختيار التاريخ.'
                : 'موصى: ${Formatters.integer(recommended)} ريال يوميًا',
            style: AppTypography.bodyStrong(Theme.of(context).colorScheme.primary),
          ),
          const SizedBox(height: AppSpacing.s6),
          FilledButton(
            onPressed: _submit,
            child: Text(widget.goal == null ? 'أنشئ الهدف' : 'حفظ التعديل'),
          ),
        ],
      ),
    );

    if (!widget.fullScreen) {
      return body;
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.goal == null ? 'هدف جديد' : 'تعديل الهدف'),
      ),
      body: body,
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
    if (widget.goal != null) {
      ref.invalidate(goalDetailsProvider(widget.goal!.id));
    }
    Navigator.of(context).pop();
  }
}
