import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/l10n_ext.dart';
import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/navy_sheet_theme.dart';
import '../../core/theme/widgets/app_toast.dart';
import '../../domain/entities/account_entity.dart';
import '../../domain/entities/card_entity.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../../engine/parser/card_network.dart';
import 'card_network_badge.dart';
import 'card_network_label.dart';
import 'card_theme.dart';
import 'cards_providers.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../common/repo_error_messages.dart';
import 'card_theme_labels.dart';
import '../../core/theme/widgets/glass_sheet.dart';
import '../../core/theme/widgets/glass_dialog.dart';
import '../../core/theme/widgets/glass_dropdown_field.dart';

/// شيت إضافة/تعديل بطاقة. [accountId] اختياري: مرَّره لربط مبدئي بحساب، أو
/// اتركه null للإضافة من صفحة البطاقات (يختار المستخدم الحساب أو «بدون»).
/// [card] للتعديل. [initialLast4]/[initialNetwork] لتخصيص بطاقة مشتقّة من
/// الرسائل (لا يوجد لها صفّ بعد) — تُنشأ عند الحفظ.
Future<void> showCardForm(
  BuildContext context,
  WidgetRef ref, {
  String? accountId,
  CardEntity? card,
  String? initialLast4,
  CardNetwork? initialNetwork,
}) {
  return showGlassSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => navySheetTheme(Directionality(
      textDirection: Directionality.of(context),
      child: Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: _CardForm(
          accountId: accountId,
          card: card,
          initialLast4: initialLast4,
          initialNetwork: initialNetwork,
        ),
      ),
    )),
  );
}

class _CardForm extends ConsumerStatefulWidget {
  const _CardForm({
    this.accountId,
    this.card,
    this.initialLast4,
    this.initialNetwork,
  });

  final String? accountId;
  final CardEntity? card;
  final String? initialLast4;
  final CardNetwork? initialNetwork;

  @override
  ConsumerState<_CardForm> createState() => _CardFormState();
}

class _CardFormState extends ConsumerState<_CardForm> {
  late final TextEditingController _nickname;
  late final TextEditingController _last4;
  late CardNetwork _network;
  late String? _accountId;
  String? _colorTheme;
  String? _accentHex;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final c = widget.card;
    _nickname = TextEditingController(text: c?.nickname ?? '');
    _last4 = TextEditingController(text: c?.last4 ?? widget.initialLast4 ?? '');
    _network = c?.network ?? widget.initialNetwork ?? CardNetwork.unknown;
    _accountId = c?.accountId ?? widget.accountId;
    _colorTheme = c?.colorTheme;
    _accentHex = c?.accentHex;
  }

  @override
  void dispose() {
    _nickname.dispose();
    _last4.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    final last4 = normalizeLast4(_last4.text);
    if (last4 == null) {
      AppToast.showError(context, context.l10n.cfEnterValidLast4);
      return;
    }
    setState(() => _busy = true);
    final repo = ref.read(cardRepositoryProvider);
    final nickname =
        _nickname.text.trim().isEmpty ? null : _nickname.text.trim();
    final now = DateTime.now().toUtc();
    var ok = false;
    try {
      if (widget.card == null) {
        await repo.create(CardEntity(
          id: '',
          accountId: _accountId,
          last4: last4,
          network: _network,
          source: CardSource.manual,
          nickname: nickname,
          colorTheme: _colorTheme,
          accentHex: _accentHex,
          createdAt: now,
          updatedAt: now,
        ));
      } else {
        // بناء صريح (لا copyWith) حتى يمكن ضبط الحساب/اللون على null.
        final current = widget.card!;
        await repo.update(CardEntity(
          id: current.id,
          accountId: _accountId,
          last4: last4,
          network: _network,
          source: current.source,
          nickname: nickname,
          colorTheme: _colorTheme,
          accentHex: _accentHex,
          createdAt: current.createdAt,
          updatedAt: now,
        ));
      }
      ok = true;
    } on RepoException catch (e) {
      if (!mounted) return;
      AppToast.showError(
        context,
        e is ValidationRepoException && e.message == 'duplicate_card'
            ? context.l10n.cfDuplicateCard
            : repoErrorMessage(context, e),
      );
    } catch (_) {
      if (!mounted) return;
      AppToast.showError(context, context.l10n.cfSaveFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!ok) return;
    _invalidate();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => GlassAlertDialog(
        title: Text(context.l10n.cfDeleteTitle),
        content: Text(context.l10n.cfDeleteCardBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              style: Theme.of(context).brightness == Brightness.dark
                  ? TextButton.styleFrom(foregroundColor: context.colors.textPrimary)
                  : null,
              child: Text(context.l10n.commonCancel)),
          TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: TextButton.styleFrom(foregroundColor: context.colors.danger),
              child: Text(context.l10n.setDelete)),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      await ref.read(cardRepositoryProvider).delete(widget.card!.id);
    } catch (_) {
      if (mounted) {
        setState(() => _busy = false);
        AppToast.showError(context, context.l10n.cfDeleteFailed);
      }
      return;
    }
    _invalidate();
    if (mounted) Navigator.of(context).pop();
  }

  void _invalidate() {
    final original = widget.accountId;
    if (original != null) ref.invalidate(accountCardsProvider(original));
    final current = _accountId;
    if (current != null) ref.invalidate(accountCardsProvider(current));
    ref.invalidate(allCardsProvider);
    ref.invalidate(accountCardGroupsProvider);
    ref.invalidate(cardSummariesProvider);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final editing = widget.card != null;
    final accounts = ref.watch(accountsProvider).valueOrNull ?? const [];
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter, AppSpacing.s2, AppSpacing.gutter, AppSpacing.s6),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(editing ? context.l10n.cfEditCard : context.l10n.cfNewCard,
                style: AppTypography.title2(c.textMain)),
            if (editing && widget.card!.source == CardSource.auto) ...[
              const SizedBox(height: 4),
              Text(context.l10n.cfAutoDetected,
                  style: AppTypography.caption(c.textLight)),
            ],
            const SizedBox(height: AppSpacing.s4),
            _preview(),
            const SizedBox(height: AppSpacing.s4),
            TextField(
              controller: _nickname,
              enabled: !_busy,
              style: AppTypography.body(c.textMain),
              decoration: InputDecoration(
                labelText: context.l10n.cfShortNameOptional,
                hintText: context.l10n.cfShortNameHint,
              ),
            ),
            const SizedBox(height: AppSpacing.s3),
            TextField(
              controller: _last4,
              enabled: !_busy,
              keyboardType: TextInputType.number,
              maxLength: 4,
              onChanged: (_) => setState(() {}),
              style: AppTypography.body(c.textMain),
              decoration: InputDecoration(
                labelText: context.l10n.cfLast4,
                counterText: '',
              ),
            ),
            const SizedBox(height: AppSpacing.s3),
            Text(context.l10n.cfNetwork,
                style: AppTypography.caption(c.textLight)),
            const SizedBox(height: AppSpacing.s2),
            GlassDropdownField<CardNetwork>(
              value: _network,
              items: [
                for (final n in CardNetwork.values)
                  DropdownMenuItem(
                      value: n, child: Text(cardNetworkLabel(context, n))),
              ],
              onChanged: _busy
                  ? null
                  : (v) => setState(() => _network = v ?? CardNetwork.unknown),
            ),
            const SizedBox(height: AppSpacing.s4),
            Text(context.l10n.cfDesign,
                style: AppTypography.caption(c.textLight)),
            const SizedBox(height: AppSpacing.s2),
            _themeRow(),
            const SizedBox(height: AppSpacing.s3),
            Text(context.l10n.cfAccentOptional,
                style: AppTypography.caption(c.textLight)),
            const SizedBox(height: AppSpacing.s2),
            _accentRow(),
            if (accounts.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.s4),
              Text(context.l10n.cfLinkedAccount,
                  style: AppTypography.caption(c.textLight)),
              const SizedBox(height: AppSpacing.s2),
              _accountField(accounts),
            ],
            const SizedBox(height: AppSpacing.s4),
            FilledButton(
              onPressed: _busy ? null : _save,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
              child: _busy
                  ? SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.5, color: c.onInk))
                  : Text(editing ? context.l10n.txdSave : context.l10n.txnAdd,
                      style: AppTypography.bodyStrong(c.onInk)),
            ),
            if (editing) ...[
              const SizedBox(height: AppSpacing.s2),
              TextButton.icon(
                onPressed: _busy ? null : _delete,
                icon: const Icon(AppLucideIcons.trash2),
                label: Text(context.l10n.cfDeleteCard),
                style: TextButton.styleFrom(
                  foregroundColor: c.danger,
                  textStyle: AppTypography.body(c.danger),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ── معاينة حيّة للبطاقة ─────────────────────────────────────────────────
  Widget _preview() {
    final last4 = normalizeLast4(_last4.text) ?? '••••';
    return Container(
      height: 120,
      padding: const EdgeInsets.all(AppSpacing.s4),
      decoration: BoxDecoration(
        gradient:
            cardGradient(context, themeKey: _colorTheme, accentHex: _accentHex),
        borderRadius: BorderRadius.circular(AppRadius.card),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(AppLucideIcons.wifi,
                  color: Colors.white.withValues(alpha: 0.85), size: 20),
              const Spacer(),
              CardNetworkBadge(network: _network),
            ],
          ),
          const Spacer(),
          Directionality(
            textDirection: TextDirection.ltr,
            child: Text('••••  $last4',
                style: AppTypography.headline(Colors.white)
                    .copyWith(letterSpacing: 2)),
          ),
        ],
      ),
    );
  }

  // ── صفّ ثيمات التصميم (افتراضي + المنسّقة) ──────────────────────────────
  Widget _themeRow() {
    final swatches = <Widget>[
      _themeSwatch(
        selected: _colorTheme == null,
        gradient: context.colors.primaryGradient,
        label: context.l10n.accDefault,
        onTap: () => setState(() => _colorTheme = null),
      ),
      for (final theme in kCardThemes)
        _themeSwatch(
          selected: _colorTheme == theme.key,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: theme.colors,
          ),
          label: cardThemeLabel(context, theme.key, theme.label),
          onTap: () => setState(() => _colorTheme = theme.key),
        ),
    ];
    return SizedBox(
      height: 62,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: swatches.length,
        separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.s3),
        itemBuilder: (_, i) => swatches[i],
      ),
    );
  }

  Widget _themeSwatch({
    required bool selected,
    required Gradient gradient,
    required String label,
    required VoidCallback onTap,
  }) {
    final c = context.colors;
    return GestureDetector(
      onTap: _busy ? null : onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 38,
            decoration: BoxDecoration(
              gradient: gradient,
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(
                color: selected ? c.primary : c.border,
                width: selected ? 2.5 : 1,
              ),
            ),
            child: selected
                ? const Icon(AppLucideIcons.check,
                    color: Colors.white, size: 18)
                : null,
          ),
          const SizedBox(height: 4),
          Text(label, style: AppTypography.caption(c.textLight)),
        ],
      ),
    );
  }

  // ── صفّ الألوان المميّزة (بدون + اللوحة المنسّقة) ────────────────────────
  Widget _accentChoice({required String? hex, required String label,
      required Widget dot}) {
    final select = _busy ? null : () => setState(() => _accentHex = hex);
    return Semantics(
      key: ValueKey('card-accent-${hex ?? 'none'}'),
      label: label,
      button: true,
      enabled: !_busy,
      selected: _accentHex == hex,
      onTap: select,
      child: ExcludeSemantics(
        child: GestureDetector(
          onTap: select,
          behavior: HitTestBehavior.opaque,
          child: SizedBox(width: 48, height: 48, child: Center(child: dot)),
        ),
      ),
    );
  }

  Widget _accentRow() {
    final c = context.colors;
    final dots = <Widget>[
      // «بدون» لون مميّز.
      _accentChoice(
        hex: null,
        label: context.l10n.cfAccentNone,
        dot: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: c.surface2,
            border: Border.all(
              color: _accentHex == null ? c.primary : c.border,
              width: _accentHex == null ? 2.5 : 1,
            ),
          ),
          child: Icon(AppLucideIcons.ban, size: 16, color: c.textLight),
        ),
      ),
      for (final hex in kCardAccentSwatches)
        _accentChoice(
          hex: hex,
          label: context.l10n.cfAccentColourName(switch (hex) {
            '#F59E0B' => 'amber',
            '#EF4444' => 'red',
            '#EC4899' => 'pink',
            '#8B5CF6' => 'purple',
            '#3B82F6' => 'blue',
            '#06B6D4' => 'cyan',
            '#10B981' => 'emerald',
            '#84CC16' => 'lime',
            '#F97316' => 'orange',
            '#14B8A6' => 'teal',
            _ => 'other',
          }),
          dot: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: parseAccent(hex),
              border: Border.all(
                color: _accentHex == hex ? c.textMain : Colors.transparent,
                width: 2.5,
              ),
            ),
            child: _accentHex == hex
                ? const Icon(AppLucideIcons.check,
                    color: Colors.white, size: 16)
                : null,
          ),
        ),
    ];
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: dots.length,
        separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.s3),
        itemBuilder: (_, i) => dots[i],
      ),
    );
  }

  // ── اختيار الحساب (يشمل «بدون حساب») ────────────────────────────────────
  Widget _accountField(List<AccountEntity> accounts) {
    final valid = accounts.any((a) => a.id == _accountId) ? _accountId : null;
    return GlassDropdownField<String?>(
      value: valid,
      items: [
        DropdownMenuItem<String?>(
          value: null,
          child: Text(context.l10n.cfNoAccount),
        ),
        for (final AccountEntity a in accounts)
          DropdownMenuItem<String?>(value: a.id, child: Text(a.name)),
      ],
      onChanged: _busy ? null : (v) => setState(() => _accountId = v),
    );
  }
}
