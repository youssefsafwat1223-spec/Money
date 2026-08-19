import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
import 'card_theme.dart';
import 'cards_providers.dart';
import '../../core/utils/app_lucide_icons.dart';

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
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => navySheetTheme(Directionality(
      textDirection: TextDirection.rtl,
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
      AppToast.show(context, 'أدخل آخر 4 أرقام صحيحة');
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
      AppToast.show(
        context,
        e is ValidationRepoException && e.message == 'duplicate_card'
            ? 'فيه بطاقة بنفس الأرقام في هذا الحساب'
            : repoExceptionMessage(e),
      );
    } catch (_) {
      if (!mounted) return;
      AppToast.show(context, 'تعذّر حفظ البطاقة — حاول مجددًا.');
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
      builder: (_) => AlertDialog(
        title: const Text('حذف البطاقة؟'),
        content: const Text(
          'حذف البطاقة لن يحذف عملياتها — تبقى محفوظة بأرقامها. '
          'ممكن تظهر بطاقة تلقائية بنفس الأرقام لو وصلت رسالة جديدة.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('إلغاء')),
          TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('حذف')),
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
        AppToast.show(context, 'تعذّر حذف البطاقة — حاول مجددًا.');
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
            Text(editing ? 'تعديل بطاقة' : 'بطاقة جديدة',
                style: AppTypography.title2(c.textMain)),
            if (editing && widget.card!.source == CardSource.auto) ...[
              const SizedBox(height: 4),
              Text('مكتشفة تلقائيًا من رسائلك',
                  style: AppTypography.caption(c.textLight)),
            ],
            const SizedBox(height: AppSpacing.s4),
            _preview(),
            const SizedBox(height: AppSpacing.s4),
            TextField(
              controller: _nickname,
              enabled: !_busy,
              style: AppTypography.body(c.textMain),
              decoration: const InputDecoration(
                labelText: 'اسم مختصر (اختياري)',
                hintText: 'مثال: راتب، سفر',
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
              decoration: const InputDecoration(
                labelText: 'آخر 4 أرقام',
                counterText: '',
              ),
            ),
            const SizedBox(height: AppSpacing.s3),
            Text('الشبكة', style: AppTypography.caption(c.textLight)),
            const SizedBox(height: AppSpacing.s2),
            DropdownButtonFormField<CardNetwork>(
              value: _network,
              items: [
                for (final n in CardNetwork.values)
                  DropdownMenuItem(value: n, child: Text(n.label)),
              ],
              onChanged: _busy
                  ? null
                  : (v) => setState(() => _network = v ?? CardNetwork.unknown),
            ),
            const SizedBox(height: AppSpacing.s4),
            Text('التصميم', style: AppTypography.caption(c.textLight)),
            const SizedBox(height: AppSpacing.s2),
            _themeRow(),
            const SizedBox(height: AppSpacing.s3),
            Text('لون مميّز (اختياري)',
                style: AppTypography.caption(c.textLight)),
            const SizedBox(height: AppSpacing.s2),
            _accentRow(),
            if (accounts.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.s4),
              Text('الحساب المرتبط', style: AppTypography.caption(c.textLight)),
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
                  : Text(editing ? 'حفظ' : 'إضافة',
                      style: AppTypography.bodyStrong(c.onInk)),
            ),
            if (editing) ...[
              const SizedBox(height: AppSpacing.s2),
              TextButton.icon(
                onPressed: _busy ? null : _delete,
                icon: Icon(AppLucideIcons.trash2, color: c.danger),
                label: Text('حذف البطاقة', style: AppTypography.body(c.danger)),
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
        label: 'افتراضي',
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
          label: theme.label,
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
  Widget _accentRow() {
    final c = context.colors;
    final dots = <Widget>[
      // «بدون» لون مميّز.
      GestureDetector(
        onTap: _busy ? null : () => setState(() => _accentHex = null),
        child: Container(
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
        GestureDetector(
          onTap: _busy ? null : () => setState(() => _accentHex = hex),
          child: Container(
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
      height: 40,
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
    return DropdownButtonFormField<String?>(
      value: valid,
      items: [
        const DropdownMenuItem<String?>(
          value: null,
          child: Text('بدون حساب'),
        ),
        for (final AccountEntity a in accounts)
          DropdownMenuItem<String?>(value: a.id, child: Text(a.name)),
      ],
      onChanged: _busy ? null : (v) => setState(() => _accountId = v),
    );
  }
}
