import '../finance/money.dart';

/// نوع الحساب/المحفظة.
enum AccountType { cash, bank, wallet, card }

AccountType accountTypeFromKey(String key) => AccountType.values.firstWhere(
      (type) => type.name == key,
      orElse: () => AccountType.bank,
    );

/// حساب/محفظة بعملته الخاصة. أساس نظام multi-currency.
class AccountEntity {
  const AccountEntity({
    required this.id,
    required this.name,
    required this.currency,
    required this.type,
    required this.isDefault,
    required this.sortOrder,
    required this.createdAt,
    required this.updatedAt,
    this.initialBalanceMoney,
    this.currentBalanceMoney,
    this.bankAccountNumber,
    this.creditLimitMoney,
    this.availableCreditMoney,
    this.paymentDueDay,
    this.walletProvider,
    this.excludeFromTotals = false,
    this.metadata,
  });

  final String id;
  final String name;

  /// عملة الحساب — تثبّت مقياس (scale) كل مبالغه (per-row currency).
  final String currency;
  final AccountType type;

  /// الرصيد الافتتاحي (يُعاد استخدام العمود القديم initial_balance؛ ليس اسمًا
  /// جديدًا). canonical fixed-precision Money; display via [initialBalance].
  final Money? initialBalanceMoney;
  final Money? currentBalanceMoney;

  /// DISPLAY-ONLY compatibility getters (presentation leaf boundaries). NEVER a
  /// write/calc/aggregation/sync-payload source — those use the `*Money` fields.
  double? get initialBalance => initialBalanceMoney?.toDouble();
  double? get currentBalance => currentBalanceMoney?.toDouble();

  /// رقم الحساب البنكي (اختياري) — يساعد مطابقة الرسائل لبعض البنوك.
  final String? bankAccountNumber;

  /// حقول بطاقة ائتمانية (type == card) — معلوماتية فقط في هذه المرحلة.
  final Money? creditLimitMoney;
  final Money? availableCreditMoney;
  double? get creditLimit => creditLimitMoney?.toDouble();
  double? get availableCredit => availableCreditMoney?.toDouble();
  final int? paymentDueDay;

  /// مزوّد المحفظة (type == wallet): فودافون كاش/أورنج كاش/…
  final String? walletProvider;

  /// استبعاد الحساب من المجاميع المالية والتحليلات المشتقة منها.
  final bool excludeFromTotals;

  /// إعدادات متقدمة مرنة (JSON): رسوم إنستاباي، سلوك السحب من الصراف، …
  final Map<String, dynamic>? metadata;

  final bool isDefault;
  final int sortOrder;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// true عندما يكون الحساب بطاقة ائتمانية (نعيد استخدام قيمة enum card).
  bool get isCreditCard => type == AccountType.card;

  AccountEntity copyWith({
    String? id,
    String? name,
    String? currency,
    AccountType? type,
    Money? initialBalanceMoney,
    Money? currentBalanceMoney,
    String? bankAccountNumber,
    Money? creditLimitMoney,
    Money? availableCreditMoney,
    int? paymentDueDay,
    String? walletProvider,
    bool? excludeFromTotals,
    Map<String, dynamic>? metadata,
    bool? isDefault,
    int? sortOrder,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return AccountEntity(
      id: id ?? this.id,
      name: name ?? this.name,
      currency: currency ?? this.currency,
      type: type ?? this.type,
      initialBalanceMoney: initialBalanceMoney ?? this.initialBalanceMoney,
      currentBalanceMoney: currentBalanceMoney ?? this.currentBalanceMoney,
      bankAccountNumber: bankAccountNumber ?? this.bankAccountNumber,
      creditLimitMoney: creditLimitMoney ?? this.creditLimitMoney,
      availableCreditMoney: availableCreditMoney ?? this.availableCreditMoney,
      paymentDueDay: paymentDueDay ?? this.paymentDueDay,
      walletProvider: walletProvider ?? this.walletProvider,
      excludeFromTotals: excludeFromTotals ?? this.excludeFromTotals,
      metadata: metadata ?? this.metadata,
      isDefault: isDefault ?? this.isDefault,
      sortOrder: sortOrder ?? this.sortOrder,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
