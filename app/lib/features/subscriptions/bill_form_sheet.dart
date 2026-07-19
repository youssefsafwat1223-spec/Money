import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/navy_sheet_theme.dart';
import '../../core/utils/id_generator.dart';
import '../../domain/entities/bill_entity.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../cards/brand_mark.dart';
import '../common/app_sheet_scaffold.dart';
import '../dashboard/dashboard_providers.dart';
import '../transactions/transactions_providers.dart';
import 'subscriptions_providers.dart';
import '../../core/theme/widgets/app_toast.dart';

class BillFormSheet extends ConsumerStatefulWidget {
  const BillFormSheet({
    super.key,
    this.bill,
    this.initialType,
    this.initialName,
  });

  final BillEntity? bill;
  final BillType? initialType;
  final String? initialName;

  static Future<void> show(
    BuildContext context, {
    BillEntity? bill,
    BillType? initialType,
    String? initialName,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => navySheetTheme(BillFormSheet(
        bill: bill,
        initialType: initialType,
        initialName: initialName,
      )),
    );
  }

  @override
  ConsumerState<BillFormSheet> createState() => _BillFormSheetState();
}

final _decimalInputFormatter = FilteringTextInputFormatter.allow(
  RegExp(r'[0-9٠-٩۰-۹.,٫٬،\s]'),
);
final _integerInputFormatter = FilteringTextInputFormatter.allow(
  RegExp(r'[0-9٠-٩۰-۹]'),
);

String _normalizeNumberInput(String input) {
  const digitMap = {
    '٠': '0',
    '١': '1',
    '٢': '2',
    '٣': '3',
    '٤': '4',
    '٥': '5',
    '٦': '6',
    '٧': '7',
    '٨': '8',
    '٩': '9',
    '۰': '0',
    '۱': '1',
    '۲': '2',
    '۳': '3',
    '۴': '4',
    '۵': '5',
    '۶': '6',
    '۷': '7',
    '۸': '8',
    '۹': '9',
  };
  final buffer = StringBuffer();
  for (final rune in input.runes) {
    final char = String.fromCharCode(rune);
    buffer.write(digitMap[char] ?? char);
  }
  var normalized = buffer.toString().trim();
  normalized = normalized
      .replaceAll(RegExp(r'\s+'), '')
      .replaceAll('٬', '')
      .replaceAll('٫', '.')
      .replaceAll('،', ',');
  if (normalized.contains('.') && normalized.contains(',')) {
    normalized = normalized.replaceAll(',', '');
  } else if (','.allMatches(normalized).length > 1) {
    normalized = normalized.replaceAll(',', '');
  } else if (normalized.contains(',')) {
    final parts = normalized.split(',');
    final looksLikeThousands =
        parts.length == 2 && parts.last.length == 3 && parts.first.isNotEmpty;
    normalized = looksLikeThousands
        ? normalized.replaceAll(',', '')
        : normalized.replaceAll(',', '.');
  }
  return normalized;
}

double? _parseDecimalInput(String input) {
  final normalized = _normalizeNumberInput(input);
  if (normalized.isEmpty) return null;
  return double.tryParse(normalized);
}

int? _parseIntegerInput(String input) {
  final normalized = _normalizeNumberInput(input);
  if (normalized.isEmpty) return null;
  return int.tryParse(normalized.split('.').first);
}

class _BillFormSheetState extends ConsumerState<BillFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _amountController;
  late final TextEditingController _customDaysController;
  late final TextEditingController _totalInstController;
  late final TextEditingController _paidCountController;
  late final TextEditingController _manualPaidController;
  late final TextEditingController _totalPurchaseController;
  late final TextEditingController _lenderController;
  late final TextEditingController _interestController;
  late BillType _type;
  late BillFrequency _frequency;
  late String _currency;
  late DateTime _nextDueDate;
  late bool _reminderOn;
  late bool _isConfirmed;
  late BillStatus _status;
  String? _accountId;
  bool _busy = false;
  bool _pickedCustom = false;
  late final String _billRequestId;
  late final String _manualPaymentRequestId;
  late final DateTime _manualPaymentPaidAt;

  @override
  void initState() {
    super.initState();
    _billRequestId = widget.bill?.id ?? IdGenerator.next();
    _manualPaymentRequestId = IdGenerator.next();
    _manualPaymentPaidAt = DateTime.now().toUtc();
    final bill = widget.bill;
    _nameController =
        TextEditingController(text: bill?.name ?? widget.initialName ?? '');
    _amountController = TextEditingController(
        text: bill == null ? '' : bill.amount.toStringAsFixed(2));
    _customDaysController =
        TextEditingController(text: bill?.customIntervalDays?.toString() ?? '');
    _totalInstController =
        TextEditingController(text: bill?.totalInstallments?.toString() ?? '');
    _paidCountController =
        TextEditingController(text: bill?.paidCount?.toString() ?? '');
    _manualPaidController = TextEditingController(
        text: bill?.manualPaidAmount?.toStringAsFixed(2) ?? '');
    _totalPurchaseController = TextEditingController(
        text: bill?.totalPurchaseAmount?.toStringAsFixed(0) ?? '');
    _lenderController = TextEditingController(text: bill?.lenderName ?? '');
    _interestController = TextEditingController(
        text: bill?.interestRate != null
            ? (bill!.interestRate! * 100).toStringAsFixed(1)
            : '');
    _type = bill?.type ?? widget.initialType ?? BillType.subscription;
    _frequency = bill?.frequency ?? BillFrequency.monthly;
    _currency = bill?.currency ?? 'SAR';
    _accountId = bill?.accountId;
    _nextDueDate =
        bill?.nextDueDate ?? DateTime.now().add(const Duration(days: 7));
    _reminderOn = bill?.reminderOn ?? true;
    _isConfirmed = bill?.isConfirmed ?? true;
    _status = bill?.status ?? BillStatus.active;
    if (bill == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final accountRepo = ref.read(accountRepositoryProvider);
        final selectedId = ref.read(activeAccountIdProvider);
        final selectedAccount =
            selectedId == null ? null : await accountRepo.getById(selectedId);
        final account = selectedAccount ?? await accountRepo.getDefault();
        if (!mounted || account == null || _accountId != null) return;
        setState(() {
          _accountId = account.id;
          _currency = account.currency;
        });
      });
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _amountController.dispose();
    _customDaysController.dispose();
    _totalInstController.dispose();
    _paidCountController.dispose();
    _manualPaidController.dispose();
    _totalPurchaseController.dispose();
    _lenderController.dispose();
    _interestController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final today = DateTime.now();
    final todayStart = DateTime(today.year, today.month, today.day);
    final initialDate = _nextDueDate.isBefore(todayStart)
        ? todayStart
        : DateTime(_nextDueDate.year, _nextDueDate.month, _nextDueDate.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: todayStart,
      lastDate: DateTime.now().add(const Duration(days: 3650)),
    );
    if (picked != null) setState(() => _nextDueDate = picked);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate() || _busy) return;
    final today = DateTime.now();
    final todayStart = DateTime(today.year, today.month, today.day);
    final dueDate = DateTime(
      _nextDueDate.year,
      _nextDueDate.month,
      _nextDueDate.day,
    );
    if (dueDate.isBefore(todayStart)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('اختار تاريخ استحقاق قادم أو اليوم.')),
      );
      return;
    }
    setState(() => _busy = true);
    var billSaved = false;
    var needsManualPayment = false;
    try {
      final now = DateTime.now().toUtc();
      final amount = _parseDecimalInput(_amountController.text.trim())!;
      final interestRaw = _parseDecimalInput(_interestController.text.trim());
      final manualPaid = _parseDecimalInput(_manualPaidController.text.trim());
      final bill = BillEntity(
        id: _billRequestId,
        name: _nameController.text.trim(),
        amount: amount,
        currency: _currency,
        type: _type,
        frequency: _frequency,
        nextDueDate: _nextDueDate,
        reminderOn: _reminderOn,
        isConfirmed: _isConfirmed,
        customIntervalDays: _frequency == BillFrequency.custom
            ? _parseIntegerInput(_customDaysController.text.trim())
            : null,
        createdAt: widget.bill?.createdAt ?? now,
        merchantId: widget.bill?.merchantId,
        status: _status,
        manualPaidAmount: manualPaid,
        totalInstallments: _type == BillType.installment
            ? _parseIntegerInput(_totalInstController.text.trim())
            : null,
        paidCount: _type == BillType.installment
            ? _parseIntegerInput(_paidCountController.text.trim())
            : null,
        totalPurchaseAmount: _type == BillType.installment
            ? _parseDecimalInput(_totalPurchaseController.text.trim())
            : null,
        lenderName: _type == BillType.installment &&
                _lenderController.text.trim().isNotEmpty
            ? _lenderController.text.trim()
            : null,
        interestRate: _type == BillType.installment && interestRaw != null
            ? interestRaw / 100
            : null,
        accountId: _accountId,
      );
      final repo = ref.read(billRepositoryProvider);
      final previousManualPaid = widget.bill?.safeManualPaidAmount ?? 0;
      final manualPaidDelta =
          ((manualPaid ?? 0) - previousManualPaid).clamp(0.0, double.infinity);
      needsManualPayment = manualPaidDelta > 0;
      late final BillEntity saved;
      if (widget.bill == null && manualPaidDelta > 0) {
        final payment = BillPaymentEntity(
          // Keep the id stable while this sheet is open. If the RPC succeeds
          // but its response times out, retrying the save remains idempotent.
          id: _manualPaymentRequestId,
          billId: bill.id,
          amount: manualPaidDelta.toDouble(),
          currency: bill.currency,
          periodStart: _manualPaymentPeriodStart(bill),
          periodEnd: _manualPaymentPeriodEnd(bill),
          paidAt: _manualPaymentPaidAt,
          installmentIndex: _manualInstallmentIndex(bill),
          note: 'مدفوع يدويًا من الفورم',
        );
        await repo.createAndRecordPayment(bill: bill, payment: payment);
        saved = bill;
        billSaved = true;
      } else {
        saved = await repo.save(bill);
        billSaved = true;
        if (manualPaidDelta > 0) {
          await repo.recordPayment(
            BillPaymentEntity(
              id: _manualPaymentRequestId,
              billId: saved.id,
              amount: manualPaidDelta.toDouble(),
              currency: saved.currency,
              periodStart: _manualPaymentPeriodStart(saved),
              periodEnd: _manualPaymentPeriodEnd(saved),
              paidAt: _manualPaymentPaidAt,
              installmentIndex: _manualInstallmentIndex(saved),
              note: 'مدفوع يدويًا من الفورم',
            ),
          );
        }
      }
      if (!mounted) return;
      ref.invalidate(billPaymentsProvider(saved.id));
      ref.invalidate(billsViewProvider);
      ref.invalidate(savedBillsProvider);
      ref.invalidate(subscriptionsProvider);
      ref.invalidate(dashboardDataProvider);
      Navigator.of(context).pop();
    } catch (e, st) {
      debugPrint('BillFormSheet._save error: $e\n$st');
      if (!mounted) return;
      final message = billSaved && needsManualPayment
          ? 'تم حفظ الفاتورة، لكن فشل تسجيل الدفعة — أعد المحاولة بنفس البيانات.'
          : e is RepoException
              ? repoExceptionMessage(e)
              : 'حدث خطأ غير متوقع أثناء الحفظ. حاول مجددًا.';
      AppToast.show(context, message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.bill == null &&
        widget.initialName == null &&
        _nameController.text.trim().isEmpty &&
        !_pickedCustom) {
      return _BillServicePicker(
        initialType: _type,
        onCustom: (type) => setState(() {
          _type = type;
          _pickedCustom = true;
        }),
        onService: (type, name) {
          setState(() {
            _type = type;
            _nameController.text = name;
          });
        },
      );
    }
    return AppSheetScaffold(
      title: widget.bill == null ? 'إضافة فاتورة' : 'تعديل فاتورة',
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            AppSpacing.s3,
            AppSpacing.gutter,
            AppSpacing.s6,
          ),
          children: [
            const SizedBox(height: AppSpacing.s3),
            _Segmented<BillType>(
              value: _type,
              values: const [BillType.subscription, BillType.installment],
              label: (value) =>
                  value == BillType.subscription ? 'اشتراك' : 'قسط',
              onChanged: (value) => setState(() => _type = value),
            ),
            const SizedBox(height: AppSpacing.s4),
            TextFormField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'اسم الفاتورة'),
              validator: (value) =>
                  value == null || value.trim().isEmpty ? 'اكتب الاسم' : null,
            ),
            const SizedBox(height: AppSpacing.s3),
            TextFormField(
              controller: _amountController,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                _decimalInputFormatter,
              ],
              decoration: const InputDecoration(labelText: 'المبلغ'),
              validator: (value) {
                final amount = _parseDecimalInput(value ?? '');
                return amount == null || amount <= 0 ? 'اكتب مبلغ صحيح' : null;
              },
            ),
            const SizedBox(height: AppSpacing.s3),
            TextFormField(
              controller: _manualPaidController,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                _decimalInputFormatter,
              ],
              decoration: InputDecoration(
                labelText: _type == BillType.installment
                    ? 'مبلغ مدفوع يدويًا'
                    : 'مدفوع من الاشتراك يدويًا',
                helperText: 'لو دفعت حاجة ومش ظهرت كعملية، سجلها هنا',
              ),
              validator: (value) {
                final raw = value?.trim() ?? '';
                if (raw.isEmpty) return null;
                final amount = _parseDecimalInput(raw);
                return amount == null || amount <= 0
                    ? 'اكتب مبلغ أكبر من صفر'
                    : null;
              },
            ),
            const SizedBox(height: AppSpacing.s3),
            ref.watch(accountsProvider).maybeWhen(
                  data: (accounts) {
                    if (accounts.isEmpty) {
                      return TextFormField(
                        initialValue: _currency,
                        readOnly: true,
                        decoration: const InputDecoration(
                          labelText: 'عملة الحساب',
                          prefixIcon:
                              Icon(Icons.account_balance_wallet_outlined),
                        ),
                      );
                    }
                    final value = accounts.any((a) => a.id == _accountId)
                        ? _accountId
                        : accounts.first.id;
                    return DropdownButtonFormField<String>(
                      value: value,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'الحساب',
                        prefixIcon: Icon(Icons.account_balance_wallet_outlined),
                      ),
                      items: [
                        for (final account in accounts)
                          DropdownMenuItem(
                            value: account.id,
                            child: Text(
                              '${account.name} · ${account.currency}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (id) {
                        if (id == null) return;
                        final account =
                            accounts.firstWhere((account) => account.id == id);
                        setState(() {
                          _accountId = account.id;
                          _currency = account.currency;
                        });
                      },
                    );
                  },
                  orElse: () => TextFormField(
                    initialValue: _currency,
                    readOnly: true,
                    decoration: const InputDecoration(
                      labelText: 'عملة الحساب',
                      prefixIcon: Icon(Icons.account_balance_wallet_outlined),
                    ),
                  ),
                ),
            const SizedBox(height: AppSpacing.s3),
            if (_type == BillType.subscription) ...[
              _Segmented<BillStatus>(
                value: _status,
                values: BillStatus.values,
                label: _statusLabel,
                onChanged: (v) => setState(() => _status = v),
              ),
              const SizedBox(height: AppSpacing.s3),
            ],
            if (_type == BillType.installment) ...[
              TextFormField(
                controller: _lenderController,
                decoration: const InputDecoration(
                    labelText: 'المقرض / الجهة (Tamara, بنك...)'),
              ),
              const SizedBox(height: AppSpacing.s3),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _totalInstController,
                      keyboardType: TextInputType.number,
                      inputFormatters: [_integerInputFormatter],
                      decoration:
                          const InputDecoration(labelText: 'عدد الأقساط الكلي'),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.s3),
                  Expanded(
                    child: TextFormField(
                      controller: _paidCountController,
                      keyboardType: TextInputType.number,
                      inputFormatters: [_integerInputFormatter],
                      decoration:
                          const InputDecoration(labelText: 'المدفوع منها'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.s3),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _totalPurchaseController,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [
                        _decimalInputFormatter,
                      ],
                      decoration: const InputDecoration(
                          labelText: 'قيمة الشراء / القرض'),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.s3),
                  Expanded(
                    child: TextFormField(
                      controller: _interestController,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [
                        _decimalInputFormatter,
                      ],
                      decoration: const InputDecoration(
                          labelText: 'الفائدة % (اختياري)', hintText: '0'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.s3),
            ],
            DropdownButtonFormField<BillFrequency>(
              value: _frequency,
              decoration: const InputDecoration(labelText: 'كل قد إيه؟'),
              items: BillFrequency.values
                  .map(
                    (frequency) => DropdownMenuItem(
                      value: frequency,
                      child: Text(_frequencyLabel(frequency)),
                    ),
                  )
                  .toList(),
              onChanged: (value) =>
                  setState(() => _frequency = value ?? BillFrequency.monthly),
            ),
            if (_frequency == BillFrequency.custom) ...[
              const SizedBox(height: AppSpacing.s3),
              TextFormField(
                controller: _customDaysController,
                keyboardType: TextInputType.number,
                inputFormatters: [_integerInputFormatter],
                decoration: const InputDecoration(labelText: 'كل كام يوم؟'),
                validator: (value) {
                  if (_frequency != BillFrequency.custom) return null;
                  final days = _parseIntegerInput(value ?? '');
                  return days == null || days <= 0
                      ? 'اكتب عدد أيام صحيح'
                      : null;
                },
              ),
            ],
            const SizedBox(height: AppSpacing.s3),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('تاريخ الاستحقاق القادم'),
              subtitle: Text(
                '${_nextDueDate.day}/${_nextDueDate.month}/${_nextDueDate.year}',
              ),
              trailing: const Icon(Icons.calendar_month_outlined),
              onTap: _pickDate,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _reminderOn,
              onChanged: (value) => setState(() => _reminderOn = value),
              title: const Text('تفعيل التذكير'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _isConfirmed,
              onChanged: (value) => setState(() => _isConfirmed = value),
              title: const Text('فاتورة مؤكدة'),
            ),
            const SizedBox(height: AppSpacing.s4),
            FilledButton(
              key: const ValueKey('bill-save-button'),
              onPressed: _busy ? null : _save,
              child: _busy
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: Colors.white,
                      ),
                    )
                  : const Text('حفظ'),
            ),
          ],
        ),
      ),
    );
  }

  String _frequencyLabel(BillFrequency frequency) => switch (frequency) {
        BillFrequency.weekly => 'أسبوعي',
        BillFrequency.monthly => 'شهري',
        BillFrequency.yearly => 'سنوي',
        BillFrequency.custom => 'مخصص',
      };

  String _statusLabel(BillStatus status) => switch (status) {
        BillStatus.active => 'نشط',
        BillStatus.paused => 'متوقف',
        BillStatus.cancelled => 'ملغي',
      };

  DateTime _manualPaymentPeriodStart(BillEntity bill) {
    final due = bill.nextDueDate.toLocal();
    return switch (bill.frequency) {
      BillFrequency.weekly => DateTime(due.year, due.month, due.day)
          .subtract(Duration(days: due.weekday - 1)),
      BillFrequency.monthly => DateTime(due.year, due.month),
      BillFrequency.yearly => DateTime(due.year),
      BillFrequency.custom => DateTime(due.year, due.month, due.day),
    };
  }

  DateTime _manualPaymentPeriodEnd(BillEntity bill) {
    final start = _manualPaymentPeriodStart(bill);
    return switch (bill.frequency) {
      BillFrequency.weekly => start.add(const Duration(days: 6)),
      BillFrequency.monthly =>
        DateTime(start.year, start.month + 1).subtract(const Duration(days: 1)),
      BillFrequency.yearly =>
        DateTime(start.year + 1).subtract(const Duration(days: 1)),
      BillFrequency.custom =>
        start.add(Duration(days: (bill.customIntervalDays ?? 1) - 1)),
    };
  }

  int? _manualInstallmentIndex(BillEntity bill) {
    if (bill.type != BillType.installment) return null;
    final index = bill.paidCount != null && bill.paidCount! > 0
        ? bill.paidCount!
        : (widget.bill?.paidCount ?? 0) + 1;
    return index.clamp(1, bill.totalInstallments ?? 9999).toInt();
  }
}

class _BillServicePicker extends StatefulWidget {
  const _BillServicePicker({
    required this.initialType,
    required this.onCustom,
    required this.onService,
  });

  final BillType initialType;
  final ValueChanged<BillType> onCustom;
  final void Function(BillType type, String name) onService;

  @override
  State<_BillServicePicker> createState() => _BillServicePickerState();
}

class _BillServicePickerState extends State<_BillServicePicker> {
  late BillType _type = widget.initialType;
  String _query = '';

  static const _subscriptions = [
    'Netflix',
    'Spotify',
    'YouTube Premium',
    'Disney+',
    'Shahid VIP',
    'OSN+',
    'Apple Music',
    'Apple TV+',
    'Amazon Prime',
    'Anghami',
    'TOD',
    'Viu',
    'WATCH IT',
    'StarzPlay',
    'Jawwy TV',
    'Weyyak',
    'Yango Play',
    'Deezer',
    'ChatGPT Plus',
    'Claude Pro',
    'GitHub Copilot',
    'Midjourney',
    'Perplexity Pro',
    'beIN SPORTS',
    'HBO Max',
    'Crunchyroll',
    'Paramount+',
    'Audible',
    'Tidal',
    'Twitch',
    'Discord Nitro',
    'PlayStation Plus',
    'Xbox Game Pass',
    'LinkedIn Premium',
    'Microsoft 365',
    'Google One',
    'Adobe Creative Cloud',
    'Canva Pro',
    'Notion',
    'Grammarly',
    'Dropbox',
    'Coursera Plus',
    'Udemy',
    'Zoom',
  ];

  static const _installments = [
    'Tamara',
    'Tabby',
    'ValU',
    'Souhoola',
    'Forsa',
    'Halan',
    'Madfu',
    'Emkan',
    'Sympl',
    'Contact',
    'Aman',
    'Shahry',
    'Khazna',
    'Postpay',
    'Cashew',
    'قسط سيارة',
    'إيجار',
    'جوال',
    'لابتوب',
    'أثاث',
    'تعليم',
    'سفر',
    'علاج',
    'زواج',
    'ذهب',
    'أجهزة منزلية',
    'كمبيوتر',
  ];

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final items =
        (_type == BillType.subscription ? _subscriptions : _installments)
            .where((item) => item.toLowerCase().contains(_query.toLowerCase()))
            .toList();
    return AppSheetScaffold(
      title: _type == BillType.subscription ? 'إضافة اشتراك' : 'إضافة قسط',
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter,
          AppSpacing.s3,
          AppSpacing.gutter,
          AppSpacing.s6,
        ),
        children: [
          const SizedBox(height: AppSpacing.s3),
          _Segmented<BillType>(
            value: _type,
            values: const [BillType.subscription, BillType.installment],
            label: (value) =>
                value == BillType.subscription ? 'اشتراكات' : 'أقساط',
            onChanged: (value) => setState(() => _type = value),
          ),
          const SizedBox(height: AppSpacing.s4),
          TextField(
            onChanged: (value) => setState(() => _query = value),
            decoration: InputDecoration(
              hintText: _type == BillType.subscription
                  ? 'ابحث عن خدمة...'
                  : 'ابحث عن قسط...',
              prefixIcon: const Icon(Icons.search),
            ),
          ),
          const SizedBox(height: AppSpacing.s4),
          InkWell(
            borderRadius: BorderRadius.circular(AppRadius.card),
            onTap: () => widget.onCustom(_type),
            child: Container(
              padding: const EdgeInsets.all(AppSpacing.s4),
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(AppRadius.card),
                border: Border.all(
                  color: c.border,
                  strokeAlign: BorderSide.strokeAlignInside,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 54,
                    height: 54,
                    decoration: BoxDecoration(
                      color: c.surface2,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Icon(Icons.edit_note_outlined, color: c.primary),
                  ),
                  const SizedBox(width: AppSpacing.s3),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _type == BillType.subscription
                              ? 'اشتراك مخصص'
                              : 'قسط مخصص',
                          style: AppTypography.bodyStrong(c.textMain),
                        ),
                        Text(
                          'أضف الاسم والمبلغ والتكرار يدويًا',
                          style: AppTypography.caption(c.textLight),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_left),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.s5),
          Text(
            'الأكثر استخدامًا',
            style: AppTypography.caption(c.textLight).copyWith(
              letterSpacing: 1.6,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: AppSpacing.s3),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: items.length,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              mainAxisSpacing: 16,
              crossAxisSpacing: 12,
              childAspectRatio: 0.78,
            ),
            itemBuilder: (context, index) {
              final name = items[index];
              return InkWell(
                borderRadius: BorderRadius.circular(AppRadius.card),
                onTap: () => widget.onService(_type, name),
                child: Column(
                  children: [
                    BrandMark(name: name, size: 56),
                    const SizedBox(height: AppSpacing.s2),
                    Text(
                      name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: AppTypography.caption(c.textLight),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _Segmented<T> extends StatelessWidget {
  const _Segmented({
    required this.value,
    required this.values,
    required this.label,
    required this.onChanged,
  });

  final T value;
  final List<T> values;
  final String Function(T value) label;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        children: [
          for (final item in values)
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(AppRadius.pill),
                onTap: () => onChanged(item),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: item == value ? c.primary : Colors.transparent,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: Text(
                    label(item),
                    textAlign: TextAlign.center,
                    style: AppTypography.caption(
                      item == value ? Colors.white : c.textLight,
                    ).copyWith(fontWeight: FontWeight.w800),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
