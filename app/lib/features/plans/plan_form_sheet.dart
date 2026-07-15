import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/id_generator.dart';
import '../../domain/entities/plan_entity.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../cards/cards_providers.dart';
import '../common/app_sheet_scaffold.dart';
import '../dashboard/dashboard_providers.dart';
import 'plans_providers.dart';

/// Create or edit a plan/envelope (travel, wedding, Ramadan…).
class PlanFormSheet extends ConsumerStatefulWidget {
  const PlanFormSheet._({this.existing});

  final PlanEntity? existing;

  static Future<void> show(BuildContext context, {PlanEntity? existing}) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => PlanFormSheet._(existing: existing),
    );
  }

  @override
  ConsumerState<PlanFormSheet> createState() => _PlanFormSheetState();
}

class _PlanFormSheetState extends ConsumerState<PlanFormSheet> {
  late final TextEditingController _nameController;
  late final TextEditingController _budgetController;
  late DateTime _start;
  late DateTime _end;
  late Set<String> _accountIds;
  late Set<String> _cards;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _nameController = TextEditingController(text: e?.name ?? '');
    _budgetController = TextEditingController(
        text: e == null ? '' : e.budgetAmount.toStringAsFixed(0));
    _start = e?.startDate ?? DateTime.now();
    _end = e?.endDate ?? DateTime.now().add(const Duration(days: 7));
    _accountIds = {...?e?.accountIds};
    _cards = {...?e?.cardLast4s};
  }

  @override
  void dispose() {
    _nameController.dispose();
    _budgetController.dispose();
    super.dispose();
  }

  Future<void> _pickDate({required bool isStart}) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: isStart ? _start : _end,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 366 * 3)),
    );
    if (picked == null) return;
    setState(() {
      if (isStart) {
        _start = picked;
        if (_end.isBefore(_start)) _end = _start;
      } else {
        _end = picked;
      }
    });
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    final budget = double.tryParse(_budgetController.text.trim()) ?? 0;
    if (name.isEmpty || budget <= 0 || _saving) return;
    setState(() => _saving = true);

    final currency = ref.read(baseCurrencyProvider).valueOrNull ?? 'SAR';
    final existing = widget.existing;
    final plan = PlanEntity(
      id: existing?.id ?? IdGenerator.next(),
      name: name,
      budgetAmount: budget,
      currency: existing?.currency ?? currency,
      startDate: DateTime(_start.year, _start.month, _start.day),
      endDate: DateTime(_end.year, _end.month, _end.day, 23, 59, 59),
      accountIds: _accountIds.toList(),
      cardLast4s: _cards.toList(),
      status: existing?.status ?? PlanStatus.active,
      createdAt: existing?.createdAt ?? DateTime.now().toUtc(),
    );
    try {
      await ref.read(planRepositoryProvider).save(plan);
      ref.invalidate(plansWithSpentProvider);
      ref.invalidate(planProgressProvider(plan.id));
      ref.invalidate(planTransactionsProvider(plan.id));
      ref.invalidate(dashboardDataProvider);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      final message = error is RepoException
          ? repoExceptionMessage(error)
          : 'حدث خطأ غير متوقع أثناء الحفظ. حاول مجددًا.';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final accounts = ref.watch(accountsProvider).valueOrNull ?? const [];
    final cards = ref.watch(cardSummariesProvider).valueOrNull ?? const [];
    final currency = Currency.arabicLabel(
        ref.watch(baseCurrencyProvider).valueOrNull ?? 'SAR');

    return AppSheetScaffold(
      title: widget.existing == null ? 'خطة جديدة' : 'تعديل الخطة',
      subtitle: 'سفر، عُرس، رمضان… ميزانية لفترة محددة بتتابع نفسها.',
      scrollable: true,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
      bottomAction: FilledButton(
        onPressed: _saving ? null : _save,
        style: FilledButton.styleFrom(
          backgroundColor: c.cta,
          foregroundColor: c.onCta,
          minimumSize: const Size.fromHeight(52),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        child: _saving
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Text('احفظ الخطة'),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _nameController,
            decoration: _dec(c, 'اسم الخطة', hint: 'مثلاً: رحلة دبي'),
          ),
          const SizedBox(height: AppSpacing.s3),
          TextField(
            controller: _budgetController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: _dec(c, 'ميزانية الخطة', suffix: currency),
          ),
          const SizedBox(height: AppSpacing.s3),
          Row(
            children: [
              Expanded(
                child:
                    _dateTile(c, 'من', _start, () => _pickDate(isStart: true)),
              ),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child:
                    _dateTile(c, 'إلى', _end, () => _pickDate(isStart: false)),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s4),
          _sectionLabel(c, 'الحسابات اللي هتصرف منها'),
          const SizedBox(height: AppSpacing.s2),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final account in accounts)
                FilterChip(
                  label: Text(
                      '${account.name} · ${Currency.arabicLabel(account.currency)}'),
                  selected: _accountIds.contains(account.id),
                  onSelected: (v) => setState(() {
                    if (v) {
                      _accountIds.add(account.id);
                    } else {
                      _accountIds.remove(account.id);
                    }
                  }),
                ),
            ],
          ),
          if (cards.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.s4),
            _sectionLabel(c, 'الكروت (اختياري)'),
            const SizedBox(height: AppSpacing.s2),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final card in cards)
                  FilterChip(
                    label: Text('بطاقة ${card.last4}'),
                    selected: _cards.contains(card.last4),
                    onSelected: (v) => setState(() {
                      if (v) {
                        _cards.add(card.last4);
                      } else {
                        _cards.remove(card.last4);
                      }
                    }),
                  ),
              ],
            ),
          ],
          const SizedBox(height: AppSpacing.s2),
          Text(
            'لو ماخترتش حساب أو كارت، الخطة هتحسب كل المصاريف في الفترة.',
            style: AppTypography.caption(c.textLight),
          ),
          const SizedBox(height: AppSpacing.s3),
        ],
      ),
    );
  }

  Widget _sectionLabel(AppColors c, String text) => Align(
        alignment: AlignmentDirectional.centerStart,
        child: Text(text, style: AppTypography.subhead(c.textMain)),
      );

  Widget _dateTile(
      AppColors c, String label, DateTime date, VoidCallback onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.s3),
        decoration: BoxDecoration(
          color: c.surface2.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: c.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: AppTypography.caption(c.textLight)),
            const SizedBox(height: 4),
            Text(Formatters.fullDate(date, context),
                style: AppTypography.subhead(c.textMain)),
          ],
        ),
      ),
    );
  }

  InputDecoration _dec(AppColors c, String label,
      {String? hint, String? suffix}) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      suffixText: suffix,
      filled: true,
      fillColor: c.surface2.withValues(alpha: 0.5),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: c.border),
      ),
    );
  }
}
