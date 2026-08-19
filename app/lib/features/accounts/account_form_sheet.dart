import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/navy_sheet_theme.dart';
import '../../core/theme/widgets/app_toast.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/id_generator.dart';
import '../../domain/entities/account_entity.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../../domain/finance/money.dart';
import '../../domain/finance/money_input.dart';
import '../../domain/usecases/account_deletion.dart';
import 'account_deletion_sheet.dart';
import '../dashboard/dashboard_providers.dart';
import '../../core/utils/app_lucide_icons.dart';

String accountTypeLabel(AccountType type) => switch (type) {
      AccountType.cash => 'نقدي',
      AccountType.bank => 'بنك',
      AccountType.wallet => 'محفظة',
      // نعيد استخدام قيمة enum card لتعني «بطاقة ائتمانية» في الواجهة فقط.
      AccountType.card => 'بطاقة ائتمانية',
    };

IconData accountTypeIcon(AccountType type) => switch (type) {
      AccountType.cash => AppLucideIcons.banknote,
      AccountType.bank => AppLucideIcons.landmark,
      AccountType.wallet => AppLucideIcons.wallet,
      AccountType.card => AppLucideIcons.creditCard,
    };

/// مزوّدو المحافظ الإلكترونية الشائعون (key → label).
const Map<String, String> _walletProviders = {
  'vodafone_cash': 'فودافون كاش',
  'orange_cash': 'أورنج كاش',
  'etisalat_cash': 'e& كاش',
  'we_pay': 'وي باي',
};

Future<void> showAccountForm(
  BuildContext context,
  WidgetRef ref, {
  AccountEntity? account,
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
        child: _AccountForm(account: account),
      ),
    )),
  );
}

class _AccountForm extends ConsumerStatefulWidget {
  const _AccountForm({this.account});

  final AccountEntity? account;

  @override
  ConsumerState<_AccountForm> createState() => _AccountFormState();
}

class _AccountFormState extends ConsumerState<_AccountForm> {
  late final TextEditingController _name;
  late final TextEditingController _startingBalance;
  late final TextEditingController _bankAccountNumber;
  late final TextEditingController _creditLimit;
  late final TextEditingController _availableCredit;
  late final TextEditingController _paymentDueDay;
  late AccountType _type;
  late String _currency;
  late bool _isDefault;
  late bool _excludeFromTotals;
  late String? _walletProvider;
  late final String _creationId;
  bool _advancedOpen = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final a = widget.account;
    _name = TextEditingController(text: a?.name ?? '');
    _startingBalance = TextEditingController(text: _numText(a?.initialBalance));
    _bankAccountNumber =
        TextEditingController(text: a?.bankAccountNumber ?? '');
    _creditLimit = TextEditingController(text: _numText(a?.creditLimit));
    _availableCredit =
        TextEditingController(text: _numText(a?.availableCredit));
    _paymentDueDay =
        TextEditingController(text: a?.paymentDueDay?.toString() ?? '');
    _type = a?.type ?? AccountType.bank;
    _currency = a?.currency ?? 'SAR';
    _isDefault = a?.isDefault ?? false;
    _excludeFromTotals = a?.excludeFromTotals ?? false;
    _walletProvider = a?.walletProvider;
    _creationId = a?.id ?? IdGenerator.next();
  }

  static String _numText(double? v) =>
      v == null ? '' : (v == v.roundToDouble() ? v.toInt().toString() : '$v');

  @override
  void dispose() {
    _name.dispose();
    _startingBalance.dispose();
    _bankAccountNumber.dispose();
    _creditLimit.dispose();
    _availableCredit.dispose();
    _paymentDueDay.dispose();
    super.dispose();
  }

  /// Parse a localized money field to canonical [Money] (exact — no double).
  /// Throws on invalid/ambiguous/over-precision input; the caller validates.
  Money? _parseMoney(TextEditingController c) {
    final t = c.text.trim();
    if (t.isEmpty) return null;
    return parseLocalizedMoney(t, _currency);
  }

  Future<void> _save() async {
    if (_busy) return;
    final name = _name.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('الرجاء إدخال اسم الحساب')),
      );
      return;
    }
    final dueDayText = _paymentDueDay.text.trim();
    final dueDay = dueDayText.isEmpty ? null : int.tryParse(dueDayText);
    if (_type == AccountType.card &&
        dueDay != null &&
        (dueDay < 1 || dueDay > 31)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('يوم السداد يجب أن يكون بين 1 و31')),
      );
      return;
    }
    // Parse the money inputs exactly (localized → canonical Money). Ambiguous /
    // over-precision input now fails validation instead of changing magnitude.
    final Money? startingBalanceMoney;
    final Money? creditLimitMoney;
    final Money? availableCreditMoney;
    try {
      startingBalanceMoney =
          _type == AccountType.card ? null : _parseMoney(_startingBalance);
      creditLimitMoney =
          _type == AccountType.card ? _parseMoney(_creditLimit) : null;
      availableCreditMoney =
          _type == AccountType.card ? _parseMoney(_availableCredit) : null;
    } on Exception {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('مبلغ غير صالح')),
      );
      return;
    }

    final repo = ref.read(accountRepositoryProvider);
    final now = DateTime.now().toUtc();
    setState(() => _busy = true);

    AccountEntity build(String id, DateTime created) => AccountEntity(
          id: id,
          name: name,
          currency: _currency,
          type: _type,
          isDefault: _isDefault,
          sortOrder: widget.account?.sortOrder ?? 0,
          createdAt: created,
          updatedAt: now,
          initialBalanceMoney: startingBalanceMoney,
          bankAccountNumber: _type == AccountType.bank
              ? (_bankAccountNumber.text.trim().isEmpty
                  ? null
                  : _bankAccountNumber.text.trim())
              : null,
          creditLimitMoney: creditLimitMoney,
          availableCreditMoney: availableCreditMoney,
          paymentDueDay: _type == AccountType.card ? dueDay : null,
          walletProvider: _type == AccountType.wallet ? _walletProvider : null,
          excludeFromTotals: _excludeFromTotals,
          metadata: widget.account?.metadata,
        );

    var saved = false;
    try {
      if (widget.account == null) {
        await repo.create(build(_creationId, now));
      } else {
        await repo.update(build(widget.account!.id, widget.account!.createdAt));
        if (_isDefault && !widget.account!.isDefault) {
          await repo.setDefault(widget.account!.id);
        }
      }
      saved = true;
    } on RepoException catch (e) {
      if (!mounted) return;
      AppToast.show(context, repoExceptionMessage(e));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('حدث خطأ غير متوقع — بياناتك محفوظة، حاول مجددًا.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!saved) return;
    ref.invalidate(accountsProvider);
    ref.invalidate(dashboardDataProvider);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    if (_busy) return;
    // MALI-016: dependency-aware deletion. Show the impact first; force an
    // explicit reassign-or-archive decision for goals/subscriptions before
    // anything is touched, then execute atomically.
    final service = ref.read(financialAccountDeletionServiceProvider);
    final accountId = widget.account!.id;
    setState(() => _busy = true);

    AccountDeletionRequest? request;
    try {
      final impact = await service.plan(accountId);
      if (!mounted) return;
      if (impact.requiresDecision) {
        request = await AccountDeletionSheet.show(context, impact);
      } else {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('حذف الحساب'),
            content: Text(_impactSummary(impact)),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('إلغاء'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('حذف'),
              ),
            ],
          ),
        );
        if (confirmed == true) {
          request = AccountDeletionRequest(accountId: accountId);
        }
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تعذّر تحضير الحذف — حاول مجددًا.')),
        );
      }
    }

    if (request == null) {
      if (mounted) setState(() => _busy = false);
      return; // cancelled, or plan failed
    }

    var deleted = false;
    try {
      final result = await service.execute(request);
      deleted = true;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_resultSummary(result))),
        );
      }
    } on StateError {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('لا يمكن حذف آخر حساب.')),
        );
      }
    } on AccountDeletionBlocked {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تعذّر الحذف — بعض العناصر تحتاج قرارًا صريحًا.'),
          ),
        );
      }
    } on RepoException catch (e) {
      if (mounted) {
        AppToast.show(
          context,
          e is ValidationRepoException && e.message.contains('last_account')
              ? 'لا يمكن حذف آخر حساب.'
              : repoExceptionMessage(e),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تعذّر حذف الحساب — حاول مجددًا.')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!deleted) return;
    ref.invalidate(accountsProvider);
    ref.read(dashboardAccountProvider.notifier).state = null;
    ref.invalidate(dashboardDataProvider);
    if (mounted) Navigator.of(context).pop();
  }

  String _impactSummary(AccountDeletionImpact i) {
    final parts = <String>['ستُفصل ${i.transactionsToDetach} عملية'];
    if (i.cardsToArchive > 0) parts.add('تُؤرشف ${i.cardsToArchive} بطاقة');
    if (i.budgetsToArchive > 0) {
      parts.add('تُؤرشف ${i.budgetsToArchive} ميزانية');
    }
    return '${parts.join('، ')}.';
  }

  String _resultSummary(AccountDeletionResult r) {
    final parts = <String>['فُصلت ${r.transactionsDetached} عملية'];
    if (r.cardsArchived > 0) parts.add('${r.cardsArchived} بطاقة مؤرشفة');
    if (r.goalsReassigned > 0) parts.add('${r.goalsReassigned} هدف مُنقول');
    if (r.goalsArchived > 0) parts.add('${r.goalsArchived} هدف مؤرشف');
    if (r.subscriptionsReassigned > 0) {
      parts.add('${r.subscriptionsReassigned} اشتراك مُنقول');
    }
    if (r.subscriptionsArchived > 0) {
      parts.add('${r.subscriptionsArchived} اشتراك مؤرشف');
    }
    return 'تم حذف الحساب — ${parts.join('، ')}.';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final editing = widget.account != null;
    final currencyCodes = ref
            .watch(activeCurrenciesProvider)
            .valueOrNull
            ?.map((currency) => currency.code)
            .toList(growable: false) ??
        const ['SAR', 'AED', 'EGP', 'USD', 'EUR', 'GBP'];
    final currencies = {_currency, ...currencyCodes}.toList(growable: false);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter, AppSpacing.s2, AppSpacing.gutter, AppSpacing.s6),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(editing ? 'تعديل حساب' : 'حساب جديد',
                style: AppTypography.title2(c.textMain)),
            const SizedBox(height: AppSpacing.s4),
            _field(
              key: const ValueKey('account-name-field'),
              controller: _name,
              label: 'اسم الحساب',
              hint: 'مثال: كاش مصر، بنك الراجحي، محفظة USD',
            ),
            const SizedBox(height: AppSpacing.s3),
            Text('النوع', style: AppTypography.caption(c.textLight)),
            const SizedBox(height: AppSpacing.s2),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final type in AccountType.values)
                  ChoiceChip(
                    label: Text(accountTypeLabel(type)),
                    avatar: Icon(accountTypeIcon(type), size: 16),
                    selected: _type == type,
                    selectedColor: c.primary.withValues(alpha: 0.16),
                    onSelected:
                        _busy ? null : (_) => setState(() => _type = type),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.s4),
            Text('العملة', style: AppTypography.caption(c.textLight)),
            const SizedBox(height: AppSpacing.s2),
            DropdownButtonFormField<String>(
              value: _currency,
              isExpanded: true,
              items: [
                for (final code in currencies)
                  DropdownMenuItem(
                    value: code,
                    child: Text('$code — ${Currency.arabicLabel(code)}'),
                  ),
              ],
              onChanged: _busy
                  ? null
                  : (v) {
                      if (v != null) setState(() => _currency = v);
                    },
            ),
            // ── حقول حسب النوع ──
            ..._typeFields(),
            const SizedBox(height: AppSpacing.s3),
            _AdvancedSection(
              open: _advancedOpen,
              onToggle: () => setState(() => _advancedOpen = !_advancedOpen),
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _isDefault,
                  onChanged: _busy || widget.account?.isDefault == true
                      ? null
                      : (v) => setState(() => _isDefault = v),
                  title: Text('الحساب الافتراضي',
                      style: AppTypography.body(c.textMain)),
                  subtitle: Text('العمليات الجديدة تتسجّل هنا تلقائيًا',
                      style: AppTypography.caption(c.textLight)),
                  activeColor: c.primary,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _excludeFromTotals,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _excludeFromTotals = v),
                  title: Text('استبعاد من الإجماليات',
                      style: AppTypography.body(c.textMain)),
                  activeColor: c.primary,
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.s4),
            FilledButton(
              key: const ValueKey('account-save-button'),
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
            if (editing && !widget.account!.isDefault) ...[
              const SizedBox(height: AppSpacing.s2),
              TextButton.icon(
                onPressed: _busy ? null : _delete,
                icon: Icon(AppLucideIcons.trash2, color: c.danger),
                label: Text('حذف الحساب', style: AppTypography.body(c.danger)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _typeFields() {
    final c = context.colors;
    switch (_type) {
      case AccountType.bank:
        return [
          const SizedBox(height: AppSpacing.s3),
          _field(
              controller: _startingBalance,
              label: 'الرصيد الافتتاحي (اختياري)',
              number: true),
          const SizedBox(height: AppSpacing.s3),
          _field(
              controller: _bankAccountNumber,
              label: 'رقم الحساب البنكي (اختياري)',
              hint: 'يساعد مطابقة الرسائل',
              number: true),
        ];
      case AccountType.card:
        return [
          const SizedBox(height: AppSpacing.s3),
          _field(
              controller: _creditLimit,
              label: 'الحد الائتماني (اختياري)',
              number: true),
          const SizedBox(height: AppSpacing.s3),
          _field(
              controller: _availableCredit,
              label: 'الرصيد المتاح (اختياري)',
              number: true),
          const SizedBox(height: AppSpacing.s3),
          _field(
              controller: _paymentDueDay,
              label: 'يوم السداد (1–31، اختياري)',
              number: true),
        ];
      case AccountType.wallet:
        return [
          const SizedBox(height: AppSpacing.s3),
          _field(
              controller: _startingBalance,
              label: 'الرصيد الافتتاحي (اختياري)',
              number: true),
          const SizedBox(height: AppSpacing.s3),
          Text('المزوّد', style: AppTypography.caption(c.textLight)),
          const SizedBox(height: AppSpacing.s2),
          DropdownButtonFormField<String?>(
            value: _walletProviders.containsKey(_walletProvider)
                ? _walletProvider
                : null,
            isExpanded: true,
            items: [
              const DropdownMenuItem<String?>(
                  value: null, child: Text('غير محدَّد')),
              for (final e in _walletProviders.entries)
                DropdownMenuItem(value: e.key, child: Text(e.value)),
            ],
            onChanged:
                _busy ? null : (v) => setState(() => _walletProvider = v),
          ),
        ];
      case AccountType.cash:
        return [
          const SizedBox(height: AppSpacing.s3),
          _field(
              controller: _startingBalance,
              label: 'الرصيد الافتتاحي (اختياري)',
              number: true),
        ];
    }
  }

  Widget _field({
    Key? key,
    required TextEditingController controller,
    required String label,
    String? hint,
    bool number = false,
  }) {
    final c = context.colors;
    return TextField(
      key: key,
      controller: controller,
      enabled: !_busy,
      keyboardType: number
          ? const TextInputType.numberWithOptions(decimal: true)
          : TextInputType.text,
      inputFormatters: number
          ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))]
          : null,
      style: AppTypography.body(c.textMain),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        filled: true,
        fillColor: c.surface2.withValues(alpha: 0.45),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: c.border),
        ),
      ),
    );
  }
}

class _AdvancedSection extends StatelessWidget {
  const _AdvancedSection({
    required this.open,
    required this.onToggle,
    required this.children,
  });

  final bool open;
  final VoidCallback onToggle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.s2),
            child: Row(
              children: [
                Icon(
                    open
                        ? AppLucideIcons.chevronUp
                        : AppLucideIcons.chevronDown,
                    color: c.textLight,
                    size: 20),
                const SizedBox(width: 6),
                Text('خيارات متقدمة', style: AppTypography.body(c.textMain)),
              ],
            ),
          ),
        ),
        if (open) ...children,
      ],
    );
  }
}
