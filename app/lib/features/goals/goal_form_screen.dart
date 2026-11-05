import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/utils/l10n_ext.dart';
import '../../domain/finance/money.dart';
import '../../domain/finance/money_input.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/qirsh_visuals.dart';
import '../../core/theme/widgets/mali_glass.dart';
import '../../core/theme/widgets/navy_sheet_theme.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/id_generator.dart';
import '../../domain/entities/goal_entity.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../common/app_button.dart';
import '../budgets/budgets_providers.dart';
import '../dashboard/dashboard_providers.dart';
import 'goals_providers.dart';
import '../../core/theme/widgets/app_toast.dart';
import '../common/app_header.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../common/repo_error_messages.dart';
import '../../core/theme/widgets/glass_pickers.dart';
import '../../core/theme/widgets/glass_dropdown_field.dart';

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
        appBar: AppHeader(
          title: widget.goal == null ? context.l10n.gfNewGoal : context.l10n.gfEditGoal,
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

    return Directionality(
      textDirection: Directionality.of(context),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: MaliGlass(
          variant: MaliGlassVariant.sheet,
          nativeMaterial: true,
          child: SizedBox(
            height: MediaQuery.of(context).size.height * 0.82,
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
                        goal == null ? context.l10n.gfNewGoal : context.l10n.gfEditGoal,
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
  String? _coverSkin;
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
    final currency = widget.goal?.currency ??
        (ref.watch(baseCurrencyProvider).valueOrNull ?? 'SAR');
    final recommended = _recommendedDailyAmount(currency);
    final cur = Currency.label(context, currency);
    return Form(
      key: _formKey,
      child: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: EdgeInsets.fromLTRB(
          AppSpacing.gutter,
          widget.fullScreen ? AppSpacing.gutter : AppSpacing.s2,
          AppSpacing.gutter,
          MediaQuery.of(context).viewInsets.bottom + AppSpacing.s6,
        ),
        children: [
          const Center(child: QirshIllustration(name: 'savings', width: 170, height: 128)),
          const SizedBox(height: 12),
          TextFormField(
            controller: _nameController,
            style: _alex(15, FontWeight.w700, 1.2, c.textMain),
            decoration: InputDecoration(
              labelText: context.l10n.gfGoalName,
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
                ? context.l10n.gfEnterGoalName
                : null,
          ),
          const SizedBox(height: AppSpacing.s4),
          TextFormField(
            controller: _amountController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: _alex(15, FontWeight.w700, 1.2, c.textMain),
            decoration: InputDecoration(
              labelText: context.l10n.gfTargetAmount,
              labelStyle: _alex(13, FontWeight.w700, 1.2, c.textLight),
              suffixText: cur,
              suffixStyle: _alex(14, FontWeight.w700, 1.2, c.textMain),
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
              try {
                if (parseLocalizedMoney(value ?? '', currency).minorUnits > 0) {
                  return null;
                }
              } catch (_) {
                return context.l10n.gfEnterValidAmount;
              }
              return context.l10n.gfEnterValidAmount;
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
                title: Text(context.l10n.gfDeadline,
                    style: _alex(14, FontWeight.w700, 1.2, c.textMain)),
                subtitle: Text(
                  _deadline == null
                      ? context.l10n.gfOptional
                      : Formatters.fullDate(_deadline!, context),
                  style: _alex(12, FontWeight.w500, 1.2, c.textLight),
                ),
                trailing:
                    Icon(AppLucideIcons.calendar, color: c.textLight, size: 20),
                onTap: _pickDeadline,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.s4),
          Text(context.l10n.goalCoverLabel,
            style: AppTypography.bodyStrong(c.textPrimary)),
          const SizedBox(height: 8),
          GridView.builder(
            padding: EdgeInsets.zero,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3, mainAxisSpacing: 8, crossAxisSpacing: 8,
              mainAxisExtent: 76),
            itemCount: 6,
            itemBuilder: (context, index) {
              final options = [
                ('photo:travel', QirshPhoto.travel, context.l10n.goalCoverTravel),
                ('photo:car', QirshPhoto.car, context.l10n.goalCoverCar),
                ('photo:home', QirshPhoto.home, context.l10n.goalCoverHome),
                ('photo:education', QirshPhoto.education, context.l10n.goalCoverEducation),
                ('photo:laptop', QirshPhoto.laptop, context.l10n.goalCoverGadgets),
                ('photo:emergency', QirshPhoto.emergency, context.l10n.goalCoverEmergency),
              ];
              final option = options[index];
              final selected = qirshGoalPhoto(_coverSkin ?? widget.goal?.vaultSkin ?? 'default_vault') == option.$2;
              return Semantics(selected: selected, button: true, label: option.$3,
                child: InkWell(onTap: _saving ? null : () => setState(() => _coverSkin = option.$1),
                  borderRadius: BorderRadius.circular(14),
                  child: Container(clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: selected ? c.cta : c.border, width: selected ? 2 : 1)),
                    child: Stack(children: [
                      Positioned.fill(child: QirshPhotoFrame(photo: option.$2, height: 76)),
                      const Positioned.fill(child: DecoratedBox(decoration: BoxDecoration(
                        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
                          colors: [Colors.transparent, Color(0x9906122E)])))),
                      Positioned(right: 8, bottom: 6, child: Text(option.$3,
                        style: AppTypography.custom(size: 11, weight: FontWeight.w500,
                          height: 1.2, color: Colors.white))),
                    ]),
                  ),
                ));
            },
          ),
          const SizedBox(height: 12),
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
                      ? AppLucideIcons.info
                      : AppLucideIcons.lightbulb,
                  color: recommended == null ? c.primary : c.success,
                  size: 18,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    recommended == null
                        ? context.l10n.gfRecommendedAfterDate
                        : context.l10n.gfRecommendedFor(Formatters.integer(recommended), cur,
                        _deadline!.difference(DateTime.now()).inDays),
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
                          Text(context.l10n.gfAutoSaving,
                              style:
                                  _alex(14, FontWeight.w700, 1.2, c.textMain)),
                          const SizedBox(height: 2),
                          Text(context.l10n.gfAutoSavingHint,
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
                            labelText: context.l10n.bdgAmount,
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
                        child: GlassDropdownField<String>(
                          value: _autoSavePeriod,
                          isDense: true,
                          decoration: InputDecoration(
                            labelText: context.l10n.gfFrequency,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(color: c.border),
                            ),
                          ),
                          items: [
                            DropdownMenuItem(
                                value: 'weekly', child: Text(context.l10n.txnCycleWeekly)),
                            DropdownMenuItem(
                                value: 'monthly', child: Text(context.l10n.txnCycleMonthly)),
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
          // زر النظام الأسود (ink) — بدل التدرّج الأزرق القديم بظلّه الكحلي.
          AppPrimaryButton(
            label: widget.goal == null ? context.l10n.gfCreateGoal : context.l10n.gfSaveEdit,
            onTap: _submit,
            loading: _saving,
            height: 52,
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
    // Seed from CANONICAL money: `_save()` parses this text straight back into
    // Money, so rounding here silently rewrites the stored target on an
    // untouched Save.
    _amountController.text = goal.targetMoney.toDecimalString();
    _deadline = goal.deadline?.toLocal();
    if (goal.hasAutoSave) {
      _autoSaveOn = true;
      _autoSaveController.text = goal.autoSaveMoney!.toDecimalString();
      _autoSavePeriod = goal.autoSavePeriod ?? 'monthly';
    }
    _seeded = true;
  }

  double? _recommendedDailyAmount(String currency) {
    final Money target;
    try {
      target = parseLocalizedMoney(_amountController.text, currency);
    } catch (_) {
      return null;
    }
    if (target.minorUnits <= 0 || _deadline == null) return null;
    // Display-only suggestion; persistence below retains canonical Money.
    final amount = target.toDouble();
    final days = _deadline!.difference(DateTime.now()).inDays;
    if (days <= 0) {
      return amount;
    }
    return amount / days;
  }

  Future<void> _pickDeadline() async {
    final picked = await showGlassDatePicker(
      context: context,
      initialDate: DateTime.now().add(const Duration(days: 90)),
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 3650)),
    );
    if (picked != null) {
      setState(() => _deadline = picked);
    }
  }

  void _invalidAmount() {
    _formKey.currentState!.validate();
    AppToast.showError(context, context.l10n.gfEnterValidAmount);
  }

  Future<void> _submit() async {
    if (_saving) return;
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      _formKey.currentState!.validate();
      AppToast.showError(context, context.l10n.gfEnterGoalName);
      return;
    }
    // Validate retained text even after the amount fields scroll offstage.
    // §25 — an existing goal keeps its persisted currency; a new one is seeded
    // from the effective base. All amounts are parsed EXACTLY from their input
    // strings into that currency.
    final currency = widget.goal?.currency ??
        (ref.read(baseCurrencyProvider).valueOrNull ?? 'SAR');
    final Money targetMoney;
    Money? autoSaveMoney;
    try {
      targetMoney = parseLocalizedMoney(_amountController.text, currency);
      if (targetMoney.minorUnits <= 0) {
        _invalidAmount();
        return;
      }
      final autoText = _autoSaveController.text.trim();
      if (_autoSaveOn && autoText.isNotEmpty) {
        final parsed = parseLocalizedMoney(autoText, currency);
        if (parsed.minorUnits < 0) {
          _invalidAmount();
          return;
        }
        if (parsed.minorUnits > 0) autoSaveMoney = parsed;
      }
    } catch (_) {
      _invalidAmount();
      return;
    }
    if (!_formKey.currentState!.validate()) return;
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
        AppToast.showError(context, context.l10n.gfPickFutureDeadline);
        return;
      }
    }
    setState(() => _saving = true);
    try {
      final accountId = widget.goal?.accountId ?? await _resolveAccountId();
      final base = widget.goal;
      final autoOn = autoSaveMoney != null;
      final goal = GoalEntity(
        id: base?.id ?? IdGenerator.next(),
        name: name,
        accountId: accountId,
        currency: currency,
        targetMoney: targetMoney,
        savedMoney: base?.savedMoney ?? Money(0, currency),
        lastNotifiedSavedMoney:
            base?.lastNotifiedSavedMoney ?? Money(0, currency),
        deadline: _deadline?.toUtc(),
        vaultSkin: _coverSkin ?? base?.vaultSkin ?? 'default_vault',
        status: base?.status ?? 'active',
        createdAt: base?.createdAt ?? DateTime.now().toUtc(),
        autoSaveMoney: autoSaveMoney,
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
          ? repoErrorMessage(context, error)
          : context.l10n.bfSaveFailed;
      AppToast.showError(context, message);
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
