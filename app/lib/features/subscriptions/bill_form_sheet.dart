import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/id_generator.dart';
import '../../domain/entities/bill_entity.dart';
import '../common/app_sheet_scaffold.dart';
import '../dashboard/dashboard_providers.dart';
import '../transactions/transactions_providers.dart';
import 'subscriptions_providers.dart';

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
      builder: (_) => BillFormSheet(
        bill: bill,
        initialType: initialType,
        initialName: initialName,
      ),
    );
  }

  @override
  ConsumerState<BillFormSheet> createState() => _BillFormSheetState();
}

// Currency options: code → Arabic display name
const _kCurrencies = <String, String>{
  'SAR': 'ريال سعودي',
  'AED': 'درهم إماراتي',
  'EGP': 'جنيه مصري',
  'KWD': 'دينار كويتي',
  'QAR': 'ريال قطري',
  'BHD': 'دينار بحريني',
  'OMR': 'ريال عماني',
  'USD': 'دولار أمريكي',
  'EUR': 'يورو',
  'GBP': 'جنيه إسترليني',
};

class _BillFormSheetState extends ConsumerState<BillFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _amountController;
  late final TextEditingController _customDaysController;
  late final TextEditingController _totalInstController;
  late final TextEditingController _paidCountController;
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
  bool _busy = false;
  bool _pickedCustom = false;

  @override
  void initState() {
    super.initState();
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
    _nextDueDate =
        bill?.nextDueDate ?? DateTime.now().add(const Duration(days: 7));
    _reminderOn = bill?.reminderOn ?? true;
    _isConfirmed = bill?.isConfirmed ?? true;
    _status = bill?.status ?? BillStatus.active;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _amountController.dispose();
    _customDaysController.dispose();
    _totalInstController.dispose();
    _paidCountController.dispose();
    _totalPurchaseController.dispose();
    _lenderController.dispose();
    _interestController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _nextDueDate,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 3650)),
    );
    if (picked != null) setState(() => _nextDueDate = picked);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate() || _busy) return;
    setState(() => _busy = true);
    final now = DateTime.now().toUtc();
    final interestRaw = double.tryParse(_interestController.text.trim());
    final bill = BillEntity(
      id: widget.bill?.id ?? IdGenerator.next(),
      name: _nameController.text.trim(),
      amount: double.parse(_amountController.text.trim()),
      currency: _currency,
      type: _type,
      frequency: _frequency,
      nextDueDate: _nextDueDate,
      reminderOn: _reminderOn,
      isConfirmed: _isConfirmed,
      customIntervalDays: _frequency == BillFrequency.custom
          ? int.tryParse(_customDaysController.text.trim())
          : null,
      createdAt: widget.bill?.createdAt ?? now,
      merchantId: widget.bill?.merchantId,
      status: _status,
      totalInstallments: _type == BillType.installment
          ? int.tryParse(_totalInstController.text.trim())
          : null,
      paidCount: _type == BillType.installment
          ? int.tryParse(_paidCountController.text.trim())
          : null,
      totalPurchaseAmount: _type == BillType.installment
          ? double.tryParse(_totalPurchaseController.text.trim())
          : null,
      lenderName: _type == BillType.installment &&
              _lenderController.text.trim().isNotEmpty
          ? _lenderController.text.trim()
          : null,
      interestRate: _type == BillType.installment && interestRaw != null
          ? interestRaw / 100
          : null,
    );
    await ref.read(billRepositoryProvider).save(bill);
    if (!mounted) return;
    ref.invalidate(billsViewProvider);
    ref.invalidate(savedBillsProvider);
    ref.invalidate(dashboardDataProvider);
    Navigator.of(context).pop();
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
          shrinkWrap: true,
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
                    decoration:
                        const InputDecoration(labelText: 'اسم الفاتورة'),
                    validator: (value) => value == null || value.trim().isEmpty
                        ? 'اكتب الاسم'
                        : null,
                  ),
                  const SizedBox(height: AppSpacing.s3),
                  TextFormField(
                    controller: _amountController,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    ],
                    decoration: const InputDecoration(labelText: 'المبلغ'),
                    validator: (value) {
                      final amount = double.tryParse((value ?? '').trim());
                      return amount == null || amount <= 0
                          ? 'اكتب مبلغ صحيح'
                          : null;
                    },
                  ),
                  const SizedBox(height: AppSpacing.s3),
                  Builder(builder: (context) {
                    final remoteCurrencies =
                        ref.watch(activeCurrenciesProvider).valueOrNull;
                    final currencies = <String, String>{
                      _currency: _kCurrencies[_currency] ?? _currency,
                      if (remoteCurrencies == null || remoteCurrencies.isEmpty)
                        ..._kCurrencies
                      else
                        for (final currency in remoteCurrencies)
                          currency.code: currency.nameAr,
                    };
                    return DropdownButtonFormField<String>(
                      value: _currency,
                      decoration: const InputDecoration(labelText: 'العملة'),
                      items: currencies.entries
                          .map((e) => DropdownMenuItem(
                                value: e.key,
                                child: Text('${e.value} (${e.key})'),
                              ))
                          .toList(),
                      onChanged: (value) =>
                          setState(() => _currency = value ?? 'SAR'),
                    );
                  }),
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
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly
                            ],
                            decoration: const InputDecoration(
                                labelText: 'عدد الأقساط الكلي'),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.s3),
                        Expanded(
                          child: TextFormField(
                            controller: _paidCountController,
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly
                            ],
                            decoration: const InputDecoration(
                                labelText: 'المدفوع منها'),
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
                            keyboardType: const TextInputType.numberWithOptions(
                                decimal: true),
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(
                                  RegExp(r'[0-9.]'))
                            ],
                            decoration: const InputDecoration(
                                labelText: 'قيمة الشراء / القرض'),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.s3),
                        Expanded(
                          child: TextFormField(
                            controller: _interestController,
                            keyboardType: const TextInputType.numberWithOptions(
                                decimal: true),
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(
                                  RegExp(r'[0-9.]'))
                            ],
                            decoration: const InputDecoration(
                                labelText: 'الفائدة % (اختياري)',
                                hintText: '0'),
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
                    onChanged: (value) => setState(
                        () => _frequency = value ?? BillFrequency.monthly),
                  ),
                  if (_frequency == BillFrequency.custom) ...[
                    const SizedBox(height: AppSpacing.s3),
                    TextFormField(
                      controller: _customDaysController,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration:
                          const InputDecoration(labelText: 'كل كام يوم؟'),
                      validator: (value) {
                        if (_frequency != BillFrequency.custom) return null;
                        final days = int.tryParse((value ?? '').trim());
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
                    onPressed: _busy ? null : _save,
                    child: Text(_busy ? 'جار الحفظ...' : 'حفظ'),
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
  ];

  static const _installments = [
    'Tamara',
    'Tabby',
    'ValU',
    'Souhoola',
    'Forsa',
    'Halan',
    'قسط سيارة',
    'إيجار',
    'جوال',
    'لابتوب',
    'أثاث',
    'تعليم',
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
        shrinkWrap: true,
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
                        _ServiceAvatar(name: name, type: _type),
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

class _ServiceAvatar extends StatelessWidget {
  const _ServiceAvatar({required this.name, required this.type});

  final String name;
  final BillType type;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final upper = name.toUpperCase();
    final brand = _brandColor(upper, c.accent);
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: brand.$1.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: c.primary.withValues(alpha: 0.10),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        brand.$2,
        style: TextStyle(
          color: brand.$1,
          fontSize: brand.$2.length > 2 ? 13 : 24,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }

  (Color, String) _brandColor(String upper, Color fallback) {
    if (upper.contains('NETFLIX')) return (const Color(0xFFE50914), 'N');
    if (upper.contains('SPOTIFY')) return (const Color(0xFF1DB954), 'S');
    if (upper.contains('YOUTUBE')) return (const Color(0xFFFF0000), 'Y');
    if (upper.contains('SHAHID')) return (const Color(0xFF00A19A), 'ش');
    if (upper.contains('APPLE')) return (Colors.black, 'A');
    if (upper.contains('AMAZON')) return (const Color(0xFFFF9900), 'a');
    if (upper.contains('CHATGPT')) return (const Color(0xFF10A37F), 'G');
    if (upper.contains('CLAUDE')) return (const Color(0xFFD97757), 'C');
    if (upper.contains('GITHUB')) return (Colors.black, 'GH');
    if (upper.contains('TABBY')) return (fallback, 'T');
    if (upper.contains('TAMARA')) return (fallback, 'T');
    if (upper.contains('VALU')) return (fallback, 'V');
    return (fallback, name.characters.first.toUpperCase());
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
