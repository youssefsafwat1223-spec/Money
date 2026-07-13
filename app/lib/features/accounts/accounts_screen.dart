import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/currency.dart';
import '../../domain/entities/account_entity.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../cards/bank_mark.dart';
import '../cards/my_cards_screen.dart';
import '../dashboard/dashboard_providers.dart';

String _accountTypeLabel(AccountType type) => switch (type) {
      AccountType.cash => 'نقدي',
      AccountType.bank => 'بنك',
      AccountType.wallet => 'محفظة',
      AccountType.card => 'بطاقة',
    };

IconData _accountTypeIcon(AccountType type) => switch (type) {
      AccountType.cash => Icons.payments_outlined,
      AccountType.bank => Icons.account_balance_outlined,
      AccountType.wallet => Icons.account_balance_wallet_outlined,
      AccountType.card => Icons.credit_card_outlined,
    };

class AccountsScreen extends ConsumerWidget {
  const AccountsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final accountsAsync = ref.watch(accountsProvider);
    return Scaffold(
      backgroundColor: c.bg,
      body: Column(
        children: [
          const _AccountsHeader(),
          Expanded(
            child: accountsAsync.when(
              skipLoadingOnReload: true,
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => const Center(child: Text('حدث خطأ')),
              data: (accounts) => ListView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.gutter,
                  AppSpacing.s4,
                  AppSpacing.gutter,
                  120,
                ),
                children: [
                  for (final account in accounts) ...[
                    _AccountCard(account: account),
                    const SizedBox(height: AppSpacing.s3),
                  ],
                  const SizedBox(height: AppSpacing.s3),
                  OutlinedButton.icon(
                    onPressed: () => _showAccountForm(context, ref),
                    icon: const Icon(Icons.add),
                    label: const Text('إضافة حساب'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                      side: BorderSide(color: c.primary.withValues(alpha: 0.4)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AccountsHeader extends StatelessWidget {
  const _AccountsHeader();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        64,
        AppSpacing.gutter,
        AppSpacing.s5,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            c.cta.withValues(alpha: 0.12),
            c.bg,
          ],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (Navigator.of(context).canPop()) ...[
                BackButton(color: c.textMain),
                const SizedBox(width: AppSpacing.s2),
              ],
              Expanded(
                child: Text(
                  'الحسابات والمحافظ',
                  style: AppTypography.title1(c.textMain)
                      .copyWith(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'كل حساب بعملته الخاصة — نقدي، بنك، محفظة أو بطاقة.',
            style: AppTypography.caption(c.textMuted),
          ),
        ],
      ),
    );
  }
}

class _AccountCard extends ConsumerWidget {
  const _AccountCard({required this.account});

  final AccountEntity account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.card),
      onTap: () => _showAccountForm(context, ref, account: account),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.s4),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: account.isDefault
              ? Border.all(
                  color: c.primary.withValues(alpha: 0.4),
                  width: 1.5,
                )
              : null,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            BankMark(
              accountName: account.name,
              accountType: account.type,
              size: 46,
            ),
            const SizedBox(width: AppSpacing.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          account.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.bodyStrong(c.textMain),
                        ),
                      ),
                      if (account.isDefault) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: c.primary.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(AppRadius.pill),
                          ),
                          child: Text('افتراضي',
                              style: AppTypography.caption(c.primary)
                                  .copyWith(fontWeight: FontWeight.w800)),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${_accountTypeLabel(account.type)} · ${Currency.arabicLabel(account.currency)} (${account.currency})',
                    style: AppTypography.caption(c.textLight),
                  ),
                ],
              ),
            ),
            Tooltip(
              message: 'بطاقاتي',
              child: GestureDetector(
                onTap: () => MyCardsScreen.open(context),
                behavior: HitTestBehavior.opaque,
                child: Container(
                  width: 40,
                  height: 28,
                  margin: const EdgeInsetsDirectional.only(end: 4),
                  decoration: BoxDecoration(
                    gradient: c.primaryGradient,
                    borderRadius: BorderRadius.circular(7),
                  ),
                  alignment: Alignment.center,
                  child: Icon(Icons.contactless,
                      color: Colors.white.withValues(alpha: 0.9), size: 14),
                ),
              ),
            ),
            Icon(Icons.chevron_left, color: c.textLight, size: 20),
          ],
        ),
      ),
    );
  }
}

Future<void> _showAccountForm(
  BuildContext context,
  WidgetRef ref, {
  AccountEntity? account,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => Directionality(
      textDirection: TextDirection.rtl,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: _AccountForm(account: account),
      ),
    ),
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
  late AccountType _type;
  late String _currency;
  late bool _isDefault;

  @override
  void initState() {
    super.initState();
    final a = widget.account;
    _name = TextEditingController(text: a?.name ?? '');
    _type = a?.type ?? AccountType.bank;
    _currency = a?.currency ?? 'SAR';
    _isDefault = a?.isDefault ?? false;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('الرجاء إدخال اسم الحساب')),
      );
      return;
    }
    final repo = ref.read(accountRepositoryProvider);
    final now = DateTime.now().toUtc();
    try {
      if (widget.account == null) {
        await repo.create(AccountEntity(
          id: '',
          name: name,
          currency: _currency,
          type: _type,
          isDefault: _isDefault,
          sortOrder: 0,
          createdAt: now,
          updatedAt: now,
        ));
      } else {
        await repo.update(widget.account!.copyWith(
          name: name,
          currency: _currency,
          type: _type,
        ));
        if (_isDefault && !widget.account!.isDefault) {
          await repo.setDefault(widget.account!.id);
        }
      }
    } on RepoException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(repoExceptionMessage(e))),
      );
      return;
    }
    ref.invalidate(accountsProvider);
    ref.invalidate(dashboardDataProvider);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final repo = ref.read(accountRepositoryProvider);
    try {
      await repo.delete(widget.account!.id);
      ref.invalidate(accountsProvider);
      ref.read(dashboardAccountProvider.notifier).state = null;
      ref.invalidate(dashboardDataProvider);
      if (mounted) Navigator.of(context).pop();
    } on StateError {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا يمكن حذف آخر حساب.')),
      );
    } on RepoException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(repoExceptionMessage(e))),
      );
    }
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
    final currencies = {
      _currency,
      ...currencyCodes,
    }.toList(growable: false);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        AppSpacing.s2,
        AppSpacing.gutter,
        AppSpacing.s6,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(editing ? 'تعديل حساب' : 'حساب جديد',
              style: AppTypography.title2(c.textMain)),
          const SizedBox(height: AppSpacing.s4),
          TextField(
            controller: _name,
            style: AppTypography.body(c.textMain),
            decoration: InputDecoration(
              labelText: 'اسم الحساب',
              hintText: 'مثال: كاش مصر، بنك الراجحي، محفظة USD',
              filled: true,
              fillColor: c.surface2.withValues(alpha: 0.45),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide(color: c.border),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.s3),
          Text('النوع', style: AppTypography.caption(c.textLight)),
          const SizedBox(height: AppSpacing.s2),
          Wrap(
            spacing: 8,
            children: [
              for (final type in AccountType.values)
                ChoiceChip(
                  label: Text(_accountTypeLabel(type)),
                  avatar: Icon(_accountTypeIcon(type), size: 16),
                  selected: _type == type,
                  selectedColor: c.primary.withValues(alpha: 0.16),
                  onSelected: (_) => setState(() => _type = type),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.s4),
          Text('العملة', style: AppTypography.caption(c.textLight)),
          const SizedBox(height: AppSpacing.s2),
          DropdownButtonFormField<String>(
            value: _currency,
            isExpanded: true,
            decoration: InputDecoration(
              filled: true,
              fillColor: c.surface2.withValues(alpha: 0.45),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide(color: c.border),
              ),
            ),
            items: [
              for (final code in currencies)
                DropdownMenuItem(
                  value: code,
                  child: Text('$code — ${Currency.arabicLabel(code)}'),
                ),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _currency = value);
            },
          ),
          const SizedBox(height: AppSpacing.s3),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _isDefault,
            onChanged: widget.account?.isDefault == true
                ? null
                : (value) => setState(() => _isDefault = value),
            title:
                Text('الحساب الافتراضي', style: AppTypography.body(c.textMain)),
            subtitle: Text('يُربط به الالتقاط التلقائي والإدخال السريع',
                style: AppTypography.caption(c.textLight)),
            activeColor: c.primary,
          ),
          const SizedBox(height: AppSpacing.s4),
          FilledButton(
            onPressed: _save,
            style: FilledButton.styleFrom(
              backgroundColor: c.primary,
              minimumSize: const Size.fromHeight(52),
            ),
            child: Text(editing ? 'حفظ' : 'إضافة',
                style: AppTypography.bodyStrong(Colors.white)),
          ),
          if (editing && !widget.account!.isDefault) ...[
            const SizedBox(height: AppSpacing.s2),
            TextButton.icon(
              onPressed: _delete,
              icon: Icon(Icons.delete_outline, color: c.danger),
              label: Text('حذف الحساب', style: AppTypography.body(c.danger)),
            ),
          ],
        ],
      ),
    );
  }
}
