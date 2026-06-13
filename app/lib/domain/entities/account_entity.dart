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
  });

  final String id;
  final String name;
  final String currency;
  final AccountType type;
  final double? initialBalance;
  final double? currentBalance;
  final bool isDefault;
  final int sortOrder;
  final DateTime createdAt;
  final DateTime updatedAt;

  AccountEntity copyWith({
    String? id,
    String? name,
    String? currency,
    AccountType? type,
    double? initialBalance,
    double? currentBalance,
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
      isDefault: isDefault ?? this.isDefault,
      sortOrder: sortOrder ?? this.sortOrder,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
