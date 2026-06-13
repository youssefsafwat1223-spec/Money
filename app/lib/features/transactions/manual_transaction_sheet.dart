import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../domain/entities/transaction_entity.dart';
import '../../engine/parser/normalizer.dart';
import '../achievements/achievements_providers.dart';
import '../budgets/budgets_providers.dart';
import '../common/category_catalog.dart';
import '../dashboard/dashboard_providers.dart';
import 'transactions_providers.dart';

class ManualTransactionSheet extends ConsumerStatefulWidget {
  const ManualTransactionSheet({super.key, this.transaction});

  final TransactionEntity? transaction;

  static Future<void> show(
    BuildContext context, {
    TransactionEntity? transaction,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ManualTransactionSheet(transaction: transaction),
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
  DateTime _occurredAt = DateTime.now();
  bool _busy = false;

  bool get _isEditing => widget.transaction != null;

  @override
  void initState() {
    super.initState();
    final tx = widget.transaction;
    if (tx != null) {
      _amount.text = tx.amount.toStringAsFixed(tx.amount.truncateToDouble() == tx.amount ? 0 : 2);
      _merchant.text = tx.rawMerchant ?? '';
      _note.text = tx.note ?? '';
      _currency.text = tx.currency;
      _type = tx.type;
      _categoryId = tx.categoryId;
      _occurredAt = tx.occurredAt.toLocal();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final settings = await ref.read(loadUserSettingsUseCaseProvider).call();
        if (mounted && _currency.text == 'SAR') {
          setState(() => _currency.text = settings.currency);
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
    final amountText = Normalizer.normalizeDigits(_amount.text)
        .replaceAll(',', '.')
        .replaceAll(RegExp(r'[^0-9.]'), '');
    final amount = double.tryParse(amountText);
    if (amount == null || amount <= 0) {
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
              currency: _currency.text.trim().toUpperCase(),
              type: _type,
              occurredAt: _occurredAt,
              rawMerchant: _merchant.text,
              categoryId: categoryId,
              note: _note.text,
            );
      } else {
        await ref.read(saveManualTransactionUseCaseProvider)(
              amount: amount,
              currency: _currency.text.trim().toUpperCase(),
              type: _type,
              occurredAt: _occurredAt,
              categoryKey: categoryKey!,
              merchant: _merchant.text,
              note: _note.text,
            );
      }
      if (!mounted) return;
      refreshTransactions(ref);
      refreshBudgets(ref);
      refreshAchievements(ref);
      ref.invalidate(dashboardDataProvider);
      Navigator.of(context).pop();
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
      await ref.read(transactionRepositoryProvider).deleteTransaction(tx.id);
      if (!mounted) return;
      refreshTransactions(ref);
      refreshBudgets(ref);
      ref.invalidate(dashboardDataProvider);
      Navigator.of(context).pop();
      Navigator.of(context).maybePop();
    } catch (_) {
      if (mounted) _snack('تعذر حذف العملية الآن.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final catalogAsync = ref.watch(categoryCatalogProvider);

    return Directionality(
      textDirection: TextDirection.rtl,
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            height: MediaQuery.of(context).size.height * 0.9,
            decoration: BoxDecoration(
              color: isDark
                  ? c.surface.withValues(alpha: 0.94)
                  : Colors.white.withValues(alpha: 0.95),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(28)),
              border: Border.all(color: c.border.withValues(alpha: 0.35)),
            ),
            child: catalogAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, stackTrace) =>
                  const Center(child: Text('تعذر تحميل التصنيفات')),
              data: (catalog) => _buildForm(context, catalog),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildForm(BuildContext context, CategoryCatalog catalog) {
    final c = context.colors;
    final categories = catalog.all.where((category) {
      if (_type == TransactionTypeEntity.income) return category.entity.isIncome;
      return !category.entity.isIncome;
    }).toList();
    if (_categoryKey == null && _categoryId == null && categories.isNotEmpty) {
      _categoryKey = categories.first.key;
    }

    return ListView(
      padding: EdgeInsets.only(
        left: AppSpacing.gutter,
        right: AppSpacing.gutter,
        top: AppSpacing.s3,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.s6,
      ),
      children: [
        Center(
          child: Container(
            width: 44,
            height: 5,
            decoration: BoxDecoration(
              color: c.textLight.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(99),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.s4),
        Row(
          children: [
            Text(
              _isEditing ? 'تعديل العملية' : 'إضافة عملية يدويًا',
              style: AppTypography.title2(c.textMain),
            ),
            const Spacer(),
            IconButton(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.s4),
        SegmentedButton<TransactionTypeEntity>(
          segments: const [
            ButtonSegment(
              value: TransactionTypeEntity.payment,
              label: Text('مصروف'),
              icon: Icon(Icons.remove_circle_outline),
            ),
            ButtonSegment(
              value: TransactionTypeEntity.income,
              label: Text('دخل'),
              icon: Icon(Icons.add_circle_outline),
            ),
            ButtonSegment(
              value: TransactionTypeEntity.transfer,
              label: Text('تحويل'),
              icon: Icon(Icons.swap_horiz),
            ),
          ],
          selected: {_type},
          onSelectionChanged: (value) {
            setState(() {
              _type = value.first;
              _categoryKey = null;
              _categoryId = null;
            });
          },
        ),
        const SizedBox(height: AppSpacing.s4),
        TextField(
          controller: _amount,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9٠-٩۰-۹.,]')),
          ],
          textDirection: TextDirection.ltr,
          decoration: const InputDecoration(
            labelText: 'المبلغ',
            prefixIcon: Icon(Icons.payments_outlined),
          ),
        ),
        const SizedBox(height: AppSpacing.s3),
        TextField(
          controller: _currency,
          textDirection: TextDirection.ltr,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(
            labelText: 'العملة',
            prefixIcon: Icon(Icons.currency_exchange),
          ),
        ),
        const SizedBox(height: AppSpacing.s3),
        DropdownButtonFormField<String>(
          value: _categoryKey ?? catalog.byId(_categoryId)?.key,
          decoration: const InputDecoration(
            labelText: 'التصنيف',
            prefixIcon: Icon(Icons.category_outlined),
          ),
          items: categories
              .map(
                (category) => DropdownMenuItem(
                  value: category.key,
                  child: Row(
                    children: [
                      Icon(category.icon, color: category.color, size: 18),
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
            prefixIcon: Icon(Icons.storefront_outlined),
          ),
        ),
        const SizedBox(height: AppSpacing.s3),
        OutlinedButton.icon(
          onPressed: _pickDateTime,
          icon: const Icon(Icons.calendar_today_outlined),
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
            prefixIcon: Icon(Icons.notes_outlined),
          ),
        ),
        const SizedBox(height: AppSpacing.s5),
        FilledButton.icon(
          onPressed: _busy ? null : () => _save(catalog),
          icon: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.check),
          label: Text(_isEditing ? 'حفظ التعديلات' : 'إضافة العملية'),
        ),
        if (_isEditing) ...[
          const SizedBox(height: AppSpacing.s2),
          OutlinedButton.icon(
            onPressed: _busy ? null : _delete,
            icon: Icon(Icons.delete_outline, color: c.danger),
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
