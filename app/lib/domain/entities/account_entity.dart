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
    this.initialBalance,
    this.currentBalance,
    this.bankAccountNumber,
    this.creditLimit,
    this.availableCredit,
    this.paymentDueDay,
    this.walletProvider,
    this.excludeFromTotals = false,
    this.metadata,
  });

  final String id;
  final String name;
  final String currency;
  final AccountType type;

  /// الرصيد الافتتاحي (يُعاد استخدام العمود القديم initial_balance؛ ليس اسمًا
  /// جديدًا). الرصيد الحالي يُحسب: initialBalance + مؤكَّد داخل − مؤكَّد خارج.
  final double? initialBalance;
  final double? currentBalance;

  /// رقم الحساب البنكي (اختياري) — يساعد مطابقة الرسائل لبعض البنوك.
  final String? bankAccountNumber;

  /// حقول بطاقة ائتمانية (type == card) — معلوماتية فقط في هذه المرحلة.
  final double? creditLimit;
  final double? availableCredit;
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
    double? initialBalance,
    double? currentBalance,
    String? bankAccountNumber,
    double? creditLimit,
    double? availableCredit,
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
      initialBalance: initialBalance ?? this.initialBalance,
      currentBalance: currentBalance ?? this.currentBalance,
      bankAccountNumber: bankAccountNumber ?? this.bankAccountNumber,
      creditLimit: creditLimit ?? this.creditLimit,
      availableCredit: availableCredit ?? this.availableCredit,
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
