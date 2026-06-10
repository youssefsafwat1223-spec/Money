import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/id_generator.dart';
import '../../domain/entities/goal_entity.dart';
import 'goals_providers.dart';

class GoalFormScreen extends ConsumerStatefulWidget {
  const GoalFormScreen({super.key});

  @override
  ConsumerState<GoalFormScreen> createState() => _GoalFormScreenState();
}

class _GoalFormScreenState extends ConsumerState<GoalFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _amountController = TextEditingController();
  DateTime? _deadline;

  @override
  void dispose() {
    _nameController.dispose();
    _amountController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final recommended = _recommendedDailyAmount();
    return Scaffold(
      appBar: AppBar(title: const Text('هدف جديد')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.gutter),
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
              child: const Text('أنشئ الهدف'),
            ),
          ],
        ),
      ),
    );
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
          GoalEntity(
            id: IdGenerator.next(),
            name: _nameController.text.trim(),
            targetAmount: double.parse(_amountController.text),
            savedAmount: 0,
            deadline: _deadline?.toUtc(),
            vaultSkin: 'default_vault',
            status: 'active',
            createdAt: DateTime.now().toUtc(),
          ),
        );
    if (!mounted) {
      return;
    }
    refreshGoals(ref);
    Navigator.of(context).pop();
  }
}
