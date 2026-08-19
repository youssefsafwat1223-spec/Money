import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/utils/async_reload_safe.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/utils/category_glyph.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/navy_sheet_theme.dart';
import '../../core/theme/widgets/segmented_control.dart';
import '../../core/utils/currency.dart';
import '../../domain/entities/transaction_entity.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../../domain/finance/money.dart';
import '../../domain/finance/money_input.dart';
import '../../domain/entities/account_entity.dart';
import '../achievements/achievements_providers.dart';
import '../budgets/budgets_providers.dart';
import '../cards/mini_card_art.dart';
import '../capture/services/captured_message_processor.dart';
import '../common/app_sheet_scaffold.dart';
import '../common/category_catalog.dart';
import '../dashboard/dashboard_providers.dart';
import '../subscriptions/subscriptions_providers.dart';
import 'transactions_providers.dart';
import '../../core/theme/widgets/app_toast.dart';
import '../../core/utils/app_lucide_icons.dart';

class ManualTransactionSheet extends ConsumerStatefulWidget {
  const ManualTransactionSheet({
    super.key,
    this.transaction,
    this.initialCardLast4,
  });

  final TransactionEntity? transaction;

  /// لما تُفتح من صفحة بطاقة معيّنة: العملية الجديدة تُنسب لهذه البطاقة.
  final String? initialCardLast4;

  static Future<void> show(
    BuildContext context, {
    TransactionEntity? transaction,
    String? cardLast4,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => navySheetTheme(ManualTransactionSheet(
        transaction: transaction,
        initialCardLast4: cardLast4,
      )),
    );
  }

  @override
  ConsumerState<ManualTransactionSheet> createState() =>
      _ManualTransactionSheetState();
}

class _ManualTransactionSheetState
    extends ConsumerState<ManualTransactionSheet> {
  final _amount = TextEditingController();
  final _merchant = TextEditingController();
  final _note = TextEditingController();
  final _currency = TextEditingController(text: 'SAR');

  TransactionTypeEntity _type = TransactionTypeEntity.payment;
  String? _categoryKey;
  String? _categoryId;
  String? _accountId;
  DateTime _occurredAt = DateTime.now();
  bool _busy = false;

  bool get _isEditing => widget.transaction != null;

  @override
  void initState() {
    super.initState();
    final tx = widget.transaction;
    if (tx != null) {
      _amount.text = tx.amountMoney.toDecimalString();
      _merchant.text = tx.rawMerchant ?? '';
      _note.text = tx.note ?? '';
      _currency.text = tx.currency;
      _accountId = tx.accountId;
      _type = tx.type;
      _categoryId = tx.categoryId;
      _occurredAt = tx.occurredAt.toLocal();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        // الحساب الافتراضي يحدّد العملة المبدئية.
        final account = await ref.read(accountRepositoryProvider).getDefault();
        if (mounted && account != null && _accountId == null) {
          setState(() {
            _accountId = account.id;
            _currency.text = account.currency;
          });
        }
      });
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    _merchant.dispose();
    _note.dispose();
    _currency.dispose();
    super.dispose();
  }

  Future<void> _pickDateTime() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _occurredAt,
      firstDate: DateTime(DateTime.now().year - 5),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      locale: const Locale('ar'),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_occurredAt),
    );
    if (time == null || !mounted) return;
    setState(() {
      _occurredAt = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
    });
  }

  Future<void> _save(CategoryCatalog catalog) async {
    if (_busy) return;
    final normalizedCurrency = _currency.text.trim().toUpperCase();
    final Money amount;
    try {
      amount = parseLocalizedMoney(_amount.text, normalizedCurrency);
    } on Exception {
      _snack('اكتب مبلغًا صحيحًا.');
      return;
    }
    if (amount.minorUnits <= 0) {
      _snack('اكتب مبلغًا صحيحًا.');
      return;
    }
    final categoryKey = _categoryKey ?? catalog.byId(_categoryId)?.key;
    final categoryId = _categoryId ?? catalog.byKey(_categoryKey)?.id;
    if (categoryKey == null && !_isEditing) {
      _snack('اختر تصنيف العملية.');
      return;
    }

    setState(() => _busy = true);
    try {
      if (_isEditing) {
        await ref.read(transactionRepositoryProvider).updateTransaction(
              transactionId: widget.transaction!.id,
              amount: amount,
              currency: normalizedCurrency,
              type: _type,
              occurredAt: _occurredAt,
              rawMerchant: _merchant.text,
              categoryId: categoryId,
              note: _note.text,
              accountId: _accountId,
            );
      } else {
        await ref.read(saveManualTransactionUseCaseProvider)(
          amount: amount,
          currency: normalizedCurrency,
          type: _type,
          occurredAt: _occurredAt,
          categoryKey: categoryKey!,
          merchant: _merchant.text,
          note: _note.text,
          accountId: _accountId,
          cardLast4: widget.initialCardLast4,
        );
      }
      if (!mounted) return;
      if (_isEditing) {
        ref.invalidate(transactionByIdProvider(widget.transaction!.id));
      }
      refreshTransactions(ref);
      refreshBudgets(ref);
      refreshAchievements(ref);
      ref.invalidate(dashboardDataProvider);
      // Manually-added/edited transactions can cross a budget threshold just
      // like SMS-captured ones — reuse the same checker so both paths alert.
      final prefs =
          await ref.read(loadNotificationPreferencesUseCaseProvider)();
      await CapturedMessageProcessor.checkBudgetAlert(
        ref.read(appDatabaseProvider),
        prefs,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
    } on RepoException catch (e) {
      if (mounted) _snack(repoExceptionMessage(e));
    } catch (_) {
      if (mounted) _snack('تعذر حفظ العملية الآن.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final tx = widget.transaction;
    if (tx == null || _busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('حذف العملية؟'),
        content: const Text('سيتم حذف العملية من التقارير والميزانيات.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      final transactionRepository = ref.read(transactionRepositoryProvider);
      final billRepository = ref.read(billRepositoryProvider);
      final affectedBillIds = await ref.read(appDatabaseProvider).transaction(
        () async {
          await transactionRepository.deleteTransaction(tx.id);
          return billRepository.deletePaymentForTransaction(tx.id);
        },
      );
      if (!mounted) return;
      for (final billId in affectedBillIds) {
        ref.invalidate(billPaymentsProvider(billId));
      }
      if (affectedBillIds.isNotEmpty) {
        ref.invalidate(savedBillsProvider);
        ref.invalidate(billsViewProvider);
      }
      refreshTransactions(ref);
      refreshBudgets(ref);
      ref.invalidate(dashboardDataProvider);
      Navigator.of(context).pop();
      Navigator.of(context).maybePop();
    } on RepoException catch (e) {
      if (mounted) _snack(repoExceptionMessage(e));
    } catch (_) {
      if (mounted) _snack('تعذر حذف العملية الآن.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmTransaction() async {
    final tx = widget.transaction;
    if (tx == null || _busy || tx.status == TransactionStatus.confirmed) {
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(confirmTransactionUseCaseProvider)(tx.id);
      if (!mounted) return;
      ref.invalidate(transactionByIdProvider(tx.id));
      refreshTransactions(ref);
      refreshBudgets(ref);
      refreshAchievements(ref);
      ref.invalidate(dashboardDataProvider);
      _snack('تم تأكيد العملية.');
    } catch (_) {
      if (mounted) _snack('تعذر تأكيد العملية الآن.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String message) {
    AppToast.show(context, message);
  }

  @override
  Widget build(BuildContext context) {
    final catalogAsync = ref.watch(categoryCatalogProvider);

    return AppSheetScaffold(
      title: _isEditing ? 'تعديل العملية' : 'إضافة عملية يدويًا',
      body: catalogAsync.when(
        skipLoadingOnReload: true,
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) =>
            const Center(child: Text('تعذر تحميل التصنيفات')),
        data: (catalog) => _buildForm(context, catalog),
      ),
    );
  }

  Widget _buildForm(BuildContext context, CategoryCatalog catalog) {
    final c = context.colors;
    final categories = catalog.all.where((category) {
      if (_type == TransactionTypeEntity.income) {
        return category.entity.isIncome;
      }
      return !category.entity.isIncome;
    }).toList();
    if (_categoryKey == null && _categoryId == null && categories.isNotEmpty) {
      _categoryKey = categories.first.key;
    }

    return ListView(
      padding: const EdgeInsets.only(
        left: AppSpacing.gutter,
        right: AppSpacing.gutter,
        bottom: AppSpacing.s6,
      ),
      children: [
        const SizedBox(height: AppSpacing.s4),
        SegmentedControl<TransactionTypeEntity>(
          value: _type,
          accent: true,
          onChanged: (value) {
            setState(() {
              _type = value;
              _categoryKey = null;
              _categoryId = null;
            });
          },
          options: const [
            SegmentOption(
                value: TransactionTypeEntity.payment,
                label: 'مصروف',
                icon: AppLucideIcons.minus),
            SegmentOption(
                value: TransactionTypeEntity.income,
                label: 'دخل',
                icon: AppLucideIcons.plus),
            SegmentOption(
                value: TransactionTypeEntity.transfer,
                label: 'تحويل',
                icon: AppLucideIcons.arrowLeftRight),
          ],
        ),
        const SizedBox(height: AppSpacing.s4),
        // Big centered amount entry (mockup `.amountfield`), tinted by kind.
        _AmountField(
          controller: _amount,
          currency: _currency.text,
          color: switch (_type) {
            TransactionTypeEntity.income => c.income,
            TransactionTypeEntity.payment ||
            TransactionTypeEntity.withdrawal =>
              c.expense,
            _ => c.textMain,
          },
          autofocus: !_isEditing,
          onChanged: () => setState(() {}),
        ),
        const SizedBox(height: AppSpacing.s3),
        ref.watch(accountsProvider).dataOrWhen(
              data: (accounts) {
                if (accounts.isEmpty) return const SizedBox.shrink();
                final value = accounts.any((a) => a.id == _accountId)
                    ? _accountId
                    : accounts.first.id;
                return DropdownButtonFormField<String>(
                  value: value,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'الحساب',
                    prefixIcon: Icon(AppLucideIcons.wallet),
                  ),
                  items: [
                    for (final account in accounts)
                      DropdownMenuItem(
                        value: account.id,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // بنك/بطاقة بيتمثّلوا ببطاقة مصغّرة حقيقية بدل
                            // نص مجرد — نفس لغة صفوف البطاقات.
                            if (account.type == AccountType.bank ||
                                account.type == AccountType.card) ...[
                              MiniCardArt(
                                width: 36,
                                themeKey: account.type == AccountType.bank
                                    ? 'navy'
                                    : 'graphite',
                              ),
                              const SizedBox(width: 10),
                            ],
                            Flexible(
                              child: Text(
                                '${account.name} · ${Currency.arabicLabel(account.currency)}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                  onChanged: (id) {
                    if (id == null) return;
                    final account = accounts.firstWhere((a) => a.id == id);
                    setState(() {
                      _accountId = id;
                      _currency.text = account.currency;
                    });
                  },
                );
              },
              orElse: () => const SizedBox.shrink(),
            ),
        const SizedBox(height: AppSpacing.s3),
        DropdownButtonFormField<String>(
          value: _categoryKey ?? catalog.byId(_categoryId)?.key,
          decoration: const InputDecoration(
            labelText: 'التصنيف',
            prefixIcon: Icon(AppLucideIcons.shapes),
          ),
          items: categories
              .map(
                (category) => DropdownMenuItem(
                  value: category.key,
                  child: Row(
                    children: [
                      CategoryGlyph(
                          name: category.iconName,
                          size: 18,
                          color: category.color),
                      const SizedBox(width: 8),
                      Text(category.nameAr),
                    ],
                  ),
                ),
              )
              .toList(),
          onChanged: (value) => setState(() {
            _categoryKey = value;
            _categoryId = catalog.byKey(value)?.id;
          }),
        ),
        const SizedBox(height: AppSpacing.s3),
        TextField(
          controller: _merchant,
          decoration: const InputDecoration(
            labelText: 'المتجر أو المصدر (اختياري)',
            prefixIcon: Icon(AppLucideIcons.store),
          ),
        ),
        const SizedBox(height: AppSpacing.s3),
        OutlinedButton.icon(
          onPressed: _pickDateTime,
          icon: const Icon(AppLucideIcons.calendar),
          label: Text(
            '${_occurredAt.year}/${_occurredAt.month.toString().padLeft(2, '0')}/${_occurredAt.day.toString().padLeft(2, '0')} · ${_occurredAt.hour.toString().padLeft(2, '0')}:${_occurredAt.minute.toString().padLeft(2, '0')}',
          ),
        ),
        const SizedBox(height: AppSpacing.s3),
        TextField(
          controller: _note,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(
            labelText: 'ملاحظة (اختياري)',
            prefixIcon: Icon(AppLucideIcons.fileText),
          ),
        ),
        const SizedBox(height: AppSpacing.s4),
        FilledButton.icon(
          onPressed: _busy ? null : () => _save(catalog),
          icon: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(AppLucideIcons.check),
          label: Text(_isEditing ? 'حفظ التعديلات' : 'إضافة العملية'),
        ),
        if (_isEditing) ...[
          const SizedBox(height: AppSpacing.s2),
          FilledButton.icon(
            onPressed: _busy ||
                    widget.transaction!.status == TransactionStatus.confirmed
                ? null
                : _confirmTransaction,
            icon: Icon(
              widget.transaction!.status == TransactionStatus.confirmed
                  ? AppLucideIcons.badgeCheck
                  : AppLucideIcons.badgeCheck,
            ),
            label: Text(
              widget.transaction!.status == TransactionStatus.confirmed
                  ? 'العملية مؤكدة'
                  : 'تأكيد العملية',
            ),
          ),
          const SizedBox(height: AppSpacing.s2),
          OutlinedButton.icon(
            onPressed: _busy ? null : _delete,
            icon: Icon(AppLucideIcons.trash2, color: c.danger),
            label: Text('حذف العملية', style: TextStyle(color: c.danger)),
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: c.danger),
            ),
          ),
        ],
      ],
    );
  }
}

/// Big centered amount entry — mockup `.amountfield` (44px, tinted by kind,
/// with the currency as a smaller trailing label).
class _AmountField extends StatelessWidget {
  const _AmountField({
    required this.controller,
    required this.currency,
    required this.color,
    required this.autofocus,
    required this.onChanged,
  });

  final TextEditingController controller;
  final String currency;
  final Color color;
  final bool autofocus;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      children: [
        Text(
          'المبلغ',
          style: AppTypography.subhead(c.textSecondary)
              .copyWith(fontSize: 12.5, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            IntrinsicWidth(
              child: TextField(
                controller: controller,
                autofocus: autofocus,
                onChanged: (_) => onChanged(),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9٠-٩۰-۹.,]')),
                ],
                textAlign: TextAlign.center,
                textDirection: TextDirection.ltr,
                cursorColor: c.cta,
                style: AppTypography.balanceHero(color).copyWith(fontSize: 44),
                decoration: InputDecoration(
                  filled: false,
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  hintText: '0',
                  hintStyle: AppTypography.balanceHero(c.textMuted)
                      .copyWith(fontSize: 44),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              currency,
              style: AppTypography.title2(c.textSecondary)
                  .copyWith(fontSize: 17, fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ],
    );
  }
}
