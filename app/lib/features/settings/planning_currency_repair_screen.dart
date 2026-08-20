import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/formatters.dart';
import '../../data/db/planning_currency_repair.dart';
import '../../domain/finance/currency_scale.dart';
import 'planning_currency_repair_providers.dart';
import 'planning_server_repair_section.dart';
import '../common/app_header.dart';
import '../../core/utils/app_lucide_icons.dart';

class PlanningCurrencyRepairScreen extends ConsumerStatefulWidget {
  const PlanningCurrencyRepairScreen({super.key});

  @override
  ConsumerState<PlanningCurrencyRepairScreen> createState() =>
      _PlanningCurrencyRepairScreenState();
}

class _PlanningCurrencyRepairScreenState
    extends ConsumerState<PlanningCurrencyRepairScreen> {
  final _globalCurrencyController = TextEditingController();
  PlanningRepairMode _mode = PlanningRepairMode.global;
  Map<String, String> _perRowCurrency = const {};
  String? _draftSignature;
  String? _validationMessage;
  bool _saving = false;

  @override
  void dispose() {
    _globalCurrencyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final repair = ref.watch(planningCurrencyRepairProvider);
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: c.bg,
        appBar: const AppHeader(title: 'تأكيد عملة التخطيط'),
        body: Column(
          children: [
            // Server-originated unresolved-currency rows (from the sync quarantine)
            // surface here regardless of the local-legacy cutover status; renders
            // nothing when there is no server repair work.
            const PlanningServerRepairSection(),
            Expanded(
              child: repair.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, stackTrace) => _LoadError(
                  onRetry: () => ref
                      .read(planningCurrencyRepairProvider.notifier)
                      .refresh(),
                ),
                data: (data) {
                  _synchronizeDraft(data);
                  return switch (data.status) {
                    PlanningRepairStatus.notRequired =>
                      const _NothingToRepair(),
                    PlanningRepairStatus.satisfied => _RepairDone(data: data),
                    PlanningRepairStatus.needsConfirmation ||
                    PlanningRepairStatus.stale =>
                      _buildConfirmation(context, data),
                  };
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _synchronizeDraft(PlanningCurrencyRepairViewData data) {
    final signature = '${data.proposedCurrency}|'
        '${data.rows.map((row) => row.id).join('|')}';
    if (_draftSignature == signature) return;
    _draftSignature = signature;
    _globalCurrencyController.text = data.proposedCurrency;
    final fallback = isSupportedCurrency(data.proposedCurrency)
        ? data.proposedCurrency
        : 'SAR';
    _perRowCurrency = {
      for (final row in data.rows) row.id: _perRowCurrency[row.id] ?? fallback,
    };
  }

  Widget _buildConfirmation(
    BuildContext context,
    PlanningCurrencyRepairViewData data,
  ) {
    final c = context.colors;
    final isStale = data.status == PlanningRepairStatus.stale;
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        AppSpacing.s4,
        AppSpacing.gutter,
        AppSpacing.s8,
      ),
      children: [
        if (isStale) ...[
          _StatusNotice(
            color: c.warning,
            background: c.warningBg,
            icon: AppLucideIcons.refreshCw,
            title: 'تغيّرت الميزانيات أو الأهداف',
            message:
                'القرار السابق لم يعد يطابق القائمة الحالية. حدّث القائمة ثم أكّد العملات مرة أخرى.',
            action: OutlinedButton.icon(
              key: const ValueKey('repair-refresh'),
              onPressed: _saving
                  ? null
                  : () => ref
                      .read(planningCurrencyRepairProvider.notifier)
                      .refresh(),
              icon: const Icon(AppLucideIcons.refreshCw),
              label: const Text('تحديث القائمة'),
            ),
          ),
          const SizedBox(height: AppSpacing.s4),
        ],
        _InfoCard(
          icon: AppLucideIcons.info,
          title: 'لماذا نحتاج تأكيدك؟',
          child: Text(
            'الميزانيات والأهداف القديمة لا تحفظ عملة مع المبلغ. لذلك لن يخمّن '
            'قرش عملتها، بل تختار أنت كيف تريد معاملتها. لن يتغيّر أي مبلغ ولن '
            'تُحذف أي بيانات. مساهمات الأهداف تتبع عملة الهدف تلقائياً.',
            style: AppTypography.body(c.textSecondary),
          ),
        ),
        const SizedBox(height: AppSpacing.s4),
        _StatusNotice(
          color: c.info,
          background: c.infoBg,
          icon: AppLucideIcons.lightbulb,
          title: 'الاقتراح الافتراضي',
          message: '${data.proposedCurrency} — '
              '${Currency.arabicLabel(data.proposedCurrency)}\n'
              'هذا اقتراح من عملتك الحالية فقط، وليس قراراً محفوظاً حتى تؤكده.',
        ),
        const SizedBox(height: AppSpacing.s5),
        Text('طريقة التأكيد', style: AppTypography.sectionTitle(c.textPrimary)),
        const SizedBox(height: AppSpacing.s2),
        _ModeCard(
          key: const ValueKey('repair-mode-global'),
          selected: _mode == PlanningRepairMode.global,
          icon: AppLucideIcons.checkCheck,
          title: 'عملة واحدة للجميع',
          subtitle: 'كل الميزانيات والأهداف الحالية تستخدم نفس العملة',
          onTap: _saving
              ? null
              : () => setState(() {
                    _mode = PlanningRepairMode.global;
                    _validationMessage = null;
                  }),
        ),
        const SizedBox(height: AppSpacing.s2),
        _ModeCard(
          key: const ValueKey('repair-mode-per-row'),
          selected: _mode == PlanningRepairMode.perRow,
          icon: AppLucideIcons.settings2,
          title: 'تحديد عملة لكل عنصر',
          subtitle: 'اختر عملة مختلفة لكل ميزانية أو هدف عند الحاجة',
          onTap: _saving
              ? null
              : () => setState(() {
                    _mode = PlanningRepairMode.perRow;
                    _validationMessage = null;
                  }),
        ),
        const SizedBox(height: AppSpacing.s5),
        if (_mode == PlanningRepairMode.global)
          _buildGlobalFields(data)
        else
          _buildPerRowFields(data),
        if (_validationMessage != null) ...[
          const SizedBox(height: AppSpacing.s3),
          Text(
            _validationMessage!,
            key: const ValueKey('repair-validation-error'),
            style: AppTypography.footnote(c.danger),
          ),
        ],
        const SizedBox(height: AppSpacing.s5),
        FilledButton(
          key: ValueKey(
            _mode == PlanningRepairMode.global
                ? 'repair-confirm-global'
                : 'repair-confirm-per-row',
          ),
          onPressed: _saving ? null : () => _confirm(data),
          child: _saving
              ? const SizedBox.square(
                  dimension: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(
                  _mode == PlanningRepairMode.global
                      ? 'تأكيد أن كل الميزانيات والأهداف الحالية تستخدم '
                          '${_globalCurrencyController.text.trim().toUpperCase()}'
                      : 'حفظ العملات المحددة',
                ),
        ),
        const SizedBox(height: AppSpacing.s2),
        TextButton(
          key: const ValueKey('repair-defer'),
          onPressed: _saving ? null : () => Navigator.of(context).maybePop(),
          child: const Text('ليس الآن — سأكمل لاحقاً'),
        ),
      ],
    );
  }

  Widget _buildGlobalFields(PlanningCurrencyRepairViewData data) {
    final c = context.colors;
    return _InfoCard(
      icon: AppLucideIcons.globe,
      title: 'كل العناصر بعملة واحدة',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            key: const ValueKey('repair-global-currency'),
            controller: _globalCurrencyController,
            enabled: !_saving,
            textCapitalization: TextCapitalization.characters,
            textDirection: TextDirection.ltr,
            maxLength: 3,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp('[a-zA-Z]')),
              LengthLimitingTextInputFormatter(3),
            ],
            onChanged: (_) {
              setState(() => _validationMessage = null);
            },
            decoration: const InputDecoration(
              labelText: 'رمز العملة',
              hintText: 'EGP',
              counterText: '',
            ),
          ),
          const SizedBox(height: AppSpacing.s3),
          Text(
            'سيسجل التأكيد أن كل الميزانيات والأهداف الحالية تستخدم هذا الرمز.',
            style: AppTypography.footnote(c.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _buildPerRowFields(PlanningCurrencyRepairViewData data) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (data.budgets.isNotEmpty) ...[
          _RowGroupTitle(
            title: 'الميزانيات',
            count: data.budgets.length,
          ),
          const SizedBox(height: AppSpacing.s2),
          for (final row in data.budgets) ...[
            _PlanningRowCurrencyCard(
              row: row,
              currency: _perRowCurrency[row.id]!,
              enabled: !_saving,
              onChanged: (currency) =>
                  setState(() => _perRowCurrency[row.id] = currency),
            ),
            const SizedBox(height: AppSpacing.s2),
          ],
          const SizedBox(height: AppSpacing.s3),
        ],
        if (data.goals.isNotEmpty) ...[
          _RowGroupTitle(title: 'الأهداف', count: data.goals.length),
          const SizedBox(height: AppSpacing.s2),
          for (final row in data.goals) ...[
            _PlanningRowCurrencyCard(
              row: row,
              currency: _perRowCurrency[row.id]!,
              enabled: !_saving,
              onChanged: (currency) =>
                  setState(() => _perRowCurrency[row.id] = currency),
            ),
            const SizedBox(height: AppSpacing.s2),
          ],
        ],
      ],
    );
  }

  Future<void> _confirm(PlanningCurrencyRepairViewData data) async {
    final controller = ref.read(planningCurrencyRepairProvider.notifier);
    final byId = {
      for (final row in data.rows) row.id: _perRowCurrency[row.id]!
    };
    final currencies = _mode == PlanningRepairMode.global
        ? [_globalCurrencyController.text]
        : byId.values;
    if (currencies.any((currency) => !isSupportedCurrency(currency))) {
      setState(() {
        _validationMessage =
            'رمز العملة غير مدعوم. استخدم رمزاً من ثلاث حروف مثل EGP أو SAR.';
      });
      return;
    }

    setState(() {
      _saving = true;
      _validationMessage = null;
    });
    try {
      if (_mode == PlanningRepairMode.global) {
        await controller.confirmGlobal(_globalCurrencyController.text);
      } else {
        await controller.confirmPerRow(byId);
      }
    } on UnsupportedCurrencyException {
      if (mounted) {
        setState(() => _validationMessage = 'رمز العملة غير مدعوم.');
      }
    } on Object {
      if (mounted) {
        setState(() => _validationMessage =
            'تعذر حفظ التأكيد الآن. لم تتغير أي من بياناتك المالية.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.icon,
    required this.title,
    required this.child,
  });

  final IconData icon;
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.cardPadding),
      decoration: BoxDecoration(
        color: c.surfaceCard,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, color: c.primary),
              const SizedBox(width: AppSpacing.s2),
              Expanded(
                child:
                    Text(title, style: AppTypography.cardTitle(c.textPrimary)),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s3),
          child,
        ],
      ),
    );
  }
}

class _StatusNotice extends StatelessWidget {
  const _StatusNotice({
    required this.color,
    required this.background,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final Color color;
  final Color background;
  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.cardPadding),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: color),
              const SizedBox(width: AppSpacing.s2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: AppTypography.cardTitle(color)),
                    const SizedBox(height: AppSpacing.s1),
                    Text(
                      message,
                      style: AppTypography.footnote(
                        Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (action != null) ...[
            const SizedBox(height: AppSpacing.s3),
            Align(alignment: AlignmentDirectional.centerStart, child: action!),
          ],
        ],
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({
    super.key,
    required this.selected,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final bool selected;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: selected ? c.ctaSoft : c.surfaceCard,
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.s4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(
              color: selected ? c.cta : c.border,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(icon, color: selected ? c.cta : c.textSecondary),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: AppTypography.subhead(c.textPrimary)),
                    const SizedBox(height: AppSpacing.s1),
                    Text(subtitle,
                        style: AppTypography.caption(c.textSecondary)),
                  ],
                ),
              ),
              Icon(
                selected ? AppLucideIcons.circleDot : AppLucideIcons.circle,
                color: selected ? c.cta : c.textMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RowGroupTitle extends StatelessWidget {
  const _RowGroupTitle({required this.title, required this.count});

  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Text('$title ($count)',
        style: AppTypography.subhead(c.textSecondary));
  }
}

class _PlanningRowCurrencyCard extends StatelessWidget {
  const _PlanningRowCurrencyCard({
    required this.row,
    required this.currency,
    required this.enabled,
    required this.onChanged,
  });

  final LegacyPlanningRepairRow row;
  final String currency;
  final bool enabled;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isBudget = row.kind == LegacyPlanningRowKind.budget;
    final currencies = kCurrencyScale.keys.toList(growable: false)..sort();
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s4),
      decoration: BoxDecoration(
        color: c.surfaceCard,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${isBudget ? 'ميزانية' : 'هدف'} · ${row.title}',
            style: AppTypography.subhead(c.textPrimary),
          ),
          const SizedBox(height: AppSpacing.s1),
          Text(
            '${isBudget ? 'المبلغ القديم' : 'المبلغ المستهدف القديم'}: '
            '${Formatters.amount(row.legacyAmount)} · بدون عملة محددة',
            style: AppTypography.caption(c.textSecondary),
          ),
          const SizedBox(height: AppSpacing.s3),
          DropdownButtonFormField<String>(
            key: ValueKey('repair-currency-${row.id}'),
            value: currency,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'اعتبرها بهذه العملة'),
            items: [
              for (final code in currencies)
                DropdownMenuItem(
                  value: code,
                  child: Text('$code — ${Currency.arabicLabel(code)}'),
                ),
            ],
            onChanged: enabled
                ? (value) {
                    if (value != null) onChanged(value);
                  }
                : null,
          ),
        ],
      ),
    );
  }
}

class _NothingToRepair extends StatelessWidget {
  const _NothingToRepair();

  @override
  Widget build(BuildContext context) => const _TerminalState(
        icon: AppLucideIcons.checkCircle,
        title: 'لا يوجد شيء يحتاج إلى إصلاح',
        message: 'لا توجد ميزانيات أو أهداف قديمة تحتاج إلى تأكيد عملتها.',
      );
}

class _RepairDone extends StatelessWidget {
  const _RepairDone({required this.data});

  final PlanningCurrencyRepairViewData data;

  @override
  Widget build(BuildContext context) {
    final manifest = data.manifest;
    final detail = manifest?.mode == PlanningRepairMode.global
        ? 'تم تأكيد ${manifest!.globalCurrency} لكل الميزانيات والأهداف الحالية.'
        : 'تم حفظ عملة مستقلة لكل ميزانية وهدف حالي.';
    return _TerminalState(
      icon: AppLucideIcons.badgeCheck,
      title: 'تم تأكيد العملات',
      message: detail,
    );
  }
}

class _TerminalState extends StatelessWidget {
  const _TerminalState({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.gutter),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 64, color: c.success),
            const SizedBox(height: AppSpacing.s4),
            Text(title, style: AppTypography.title1(c.textPrimary)),
            const SizedBox(height: AppSpacing.s2),
            Text(
              message,
              textAlign: TextAlign.center,
              style: AppTypography.body(c.textSecondary),
            ),
            const SizedBox(height: AppSpacing.s5),
            OutlinedButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text('العودة إلى الإعدادات'),
            ),
          ],
        ),
      ),
    );
  }
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.gutter),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(AppLucideIcons.alertCircle, color: c.danger, size: 48),
            const SizedBox(height: AppSpacing.s3),
            Text(
              'تعذر قراءة بيانات التخطيط. لم يتغير أي شيء.',
              textAlign: TextAlign.center,
              style: AppTypography.body(c.textSecondary),
            ),
            const SizedBox(height: AppSpacing.s3),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(AppLucideIcons.refreshCw),
              label: const Text('إعادة المحاولة'),
            ),
          ],
        ),
      ),
    );
  }
}
