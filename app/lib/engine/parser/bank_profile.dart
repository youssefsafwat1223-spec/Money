import '../models/transaction_source.dart';
import '../models/transaction_type.dart';

/// ملف تعريف بنك/محفظة (P0 للسوق السعودي).
///
/// هذا هيكل مبدئي: الكشف عبر كلمات مفتاحية في النص أو معرّف المرسِل.
/// Codex يوسّعه بقواعد regex لكل بنك من SAUDI_MARKET_SPEC.md وبقاعدة
/// بيانات `parsing_rules` القابلة للتحديث عن بُعد.
class BankProfile {
  const BankProfile({
    required this.bankKey,
    required this.displayName,
    required this.keywords,
    this.country,
    this.locale,
    this.senderIds = const [],
    this.currencyAliases = const {},
    this.ignoreRules = const [],
    this.typeRules = const {},
    this.amountRules = const [],
    this.balanceRules = const [],
    this.feeRules = const [],
    this.totalDueRules = const [],
    this.merchantRules = const [],
    this.dateRules = const [],
    this.currencyDecimals = 2,
    this.fundingWallets = const [],
    this.preferredDateOrder = 'dmy',
    this.version = 1,
    this.defaultSource = TransactionSource.bank,
  });

  final String bankKey;
  final String displayName;
  final List<String> keywords;
  final String? country;
  final String? locale;
  final List<String> senderIds;
  final Map<String, String> currencyAliases;
  final List<String> ignoreRules;
  final Map<TransactionType, List<String>> typeRules;
  final List<String> amountRules;
  final List<String> balanceRules;
  final List<String> feeRules;
  final List<String> totalDueRules;
  final List<String> merchantRules;
  final List<String> dateRules;
  final int currencyDecimals;
  final List<String> fundingWallets;
  final String preferredDateOrder;
  final int version;
  final TransactionSource defaultSource;

  BankProfile copyWith({
    String? bankKey,
    String? displayName,
    List<String>? keywords,
    String? country,
    String? locale,
    List<String>? senderIds,
    Map<String, String>? currencyAliases,
    List<String>? ignoreRules,
    Map<TransactionType, List<String>>? typeRules,
    List<String>? amountRules,
    List<String>? balanceRules,
    List<String>? feeRules,
    List<String>? totalDueRules,
    List<String>? merchantRules,
    List<String>? dateRules,
    int? currencyDecimals,
    List<String>? fundingWallets,
    String? preferredDateOrder,
    int? version,
    TransactionSource? defaultSource,
  }) {
    return BankProfile(
      bankKey: bankKey ?? this.bankKey,
      displayName: displayName ?? this.displayName,
      keywords: keywords ?? this.keywords,
      country: country ?? this.country,
      locale: locale ?? this.locale,
      senderIds: senderIds ?? this.senderIds,
      currencyAliases: currencyAliases ?? this.currencyAliases,
      ignoreRules: ignoreRules ?? this.ignoreRules,
      typeRules: typeRules ?? this.typeRules,
      amountRules: amountRules ?? this.amountRules,
      balanceRules: balanceRules ?? this.balanceRules,
      feeRules: feeRules ?? this.feeRules,
      totalDueRules: totalDueRules ?? this.totalDueRules,
      merchantRules: merchantRules ?? this.merchantRules,
      dateRules: dateRules ?? this.dateRules,
      currencyDecimals: currencyDecimals ?? this.currencyDecimals,
      fundingWallets: fundingWallets ?? this.fundingWallets,
      preferredDateOrder: preferredDateOrder ?? this.preferredDateOrder,
      version: version ?? this.version,
      defaultSource: defaultSource ?? this.defaultSource,
    );
  }

  bool matchesSender(String? senderId) {
    final sender = senderId?.trim().toLowerCase();
    if (sender == null || sender.isEmpty) return false;
    return [...senderIds, ...keywords]
        .any((item) => sender.contains(item.toLowerCase()));
  }
}

/// سجل البنوك المدعومة في الـ MVP (السعودية — P0).
class BankProfiles {
  BankProfiles._();

  static const List<BankProfile> all = [
    BankProfile(
      bankKey: 'snb',
      displayName: 'الأهلي السعودي',
      country: 'SA',
      locale: 'ar-SA',
      senderIds: ['snb', 'alahli', 'al ahli'],
      keywords: ['الأهلي', 'snb', 'الاهلي'],
      amountRules: ['مبلغ', 'amount'],
      balanceRules: ['الرصيد', 'balance', 'available'],
      merchantRules: ['لدى', 'at'],
      dateRules: ['في', 'on'],
    ),
    BankProfile(
      bankKey: 'alrajhi',
      displayName: 'الراجحي',
      country: 'SA',
      locale: 'ar-SA',
      senderIds: ['rajhi', 'alrajhi'],
      keywords: ['الراجحي', 'rajhi'],
      amountRules: ['مبلغ', 'amount'],
      balanceRules: ['الرصيد', 'balance', 'available'],
      merchantRules: ['لدى', 'at'],
      dateRules: ['في', 'on'],
    ),
    BankProfile(
      bankKey: 'riyad',
      displayName: 'بنك الرياض',
      country: 'SA',
      locale: 'ar-SA',
      senderIds: ['riyad'],
      keywords: ['الرياض', 'riyad'],
      amountRules: ['مبلغ', 'amount'],
      balanceRules: ['الرصيد', 'balance', 'available'],
      merchantRules: ['لدى', 'at'],
      dateRules: ['في', 'on'],
    ),
    BankProfile(
      bankKey: 'stcpay',
      displayName: 'STC Pay',
      country: 'SA',
      locale: 'ar-SA',
      senderIds: ['stcpay', 'stc pay'],
      keywords: ['stc pay', 'stcpay'],
      amountRules: ['المبلغ', 'amount'],
      balanceRules: ['الرصيد', 'balance'],
      merchantRules: ['لدى', 'at'],
      defaultSource: TransactionSource.wallet,
    ),
    BankProfile(
      bankKey: 'cib',
      displayName: 'CIB مصر',
      country: 'EG',
      locale: 'ar-EG',
      senderIds: ['cib'],
      keywords: ['cib'],
      typeRules: {
        TransactionType.payment: ['خصم'],
        TransactionType.income: ['إيداع', 'ايداع', 'credited'],
        TransactionType.withdrawal: ['سحب نقدي', 'atm'],
      },
      balanceRules: ['المتاح', 'الرصيد المتاح'],
      feeRules: [],
      totalDueRules: [],
      merchantRules: ['عند'],
      fundingWallets: [],
      defaultSource: TransactionSource.card,
    ),
    BankProfile(
      bankKey: 'nbe',
      displayName: 'البنك الأهلي المصري',
      country: 'EG',
      locale: 'ar-EG',
      senderIds: ['nbe', 'NBE', 'ahlybank', 'AlAhlyBank'],
      keywords: ['nbe', 'الأهلي المصري'],
      typeRules: {
        TransactionType.payment: ['خصم', 'شراء'],
        TransactionType.income: ['إيداع', 'ايداع', 'credited'],
        TransactionType.withdrawal: ['سحب', 'atm'],
      },
      balanceRules: ['المتاح', 'الرصيد المتاح', 'الرصيد'],
      merchantRules: ['عند', 'لدى'],
      defaultSource: TransactionSource.card,
    ),
    BankProfile(
      bankKey: 'banque_misr',
      displayName: 'بنك مصر',
      country: 'EG',
      locale: 'ar-EG',
      senderIds: ['banquemisr', 'banque misr', 'bm'],
      keywords: ['بنك مصر', 'banquemisr'],
      typeRules: {
        TransactionType.payment: ['خصم'],
        TransactionType.income: ['إيداع', 'ايداع', 'credited'],
      },
      balanceRules: ['المتاح', 'الرصيد'],
      merchantRules: ['عند', 'لدى'],
    ),
    BankProfile(
      bankKey: 'd360',
      displayName: 'D360 Bank',
      country: 'SA',
      locale: 'ar-SA',
      senderIds: ['d360', 'D360', 'd360bank'],
      keywords: ['d360'],
      typeRules: {
        TransactionType.payment: [
          'International Online Purchase',
          'Online Purchase',
          'Purchase'
        ],
        TransactionType.transfer: ['transfer'],
        TransactionType.income: ['deposit', 'credited'],
      },
      amountRules: ['Amount:'],
      balanceRules: ['Available Balance:'],
      feeRules: ['Fee:'],
      merchantRules: ['At:'],
      fundingWallets: [],
      preferredDateOrder: 'ymd',
    ),
    BankProfile(
      bankKey: 'urpay',
      displayName: 'urpay',
      country: 'SA',
      locale: 'ar-SA',
      senderIds: ['urpay'],
      keywords: ['urpay'],
      typeRules: {
        TransactionType.payment: ['شراء إنترنت', 'شراء'],
        TransactionType.income: ['إيداع', 'إضافة'],
        TransactionType.transfer: ['تحويل', 'حوالة'],
      },
      amountRules: ['مبلغ:'],
      balanceRules: ['الرصيد المتاح:', 'الرصيد'],
      feeRules: ['الرسوم/الضريبة:', 'الرسوم:', 'الضريبة:'],
      merchantRules: ['من:', 'لدى:'],
      fundingWallets: ['barq'],
    ),
    BankProfile(
      bankKey: 'saib',
      displayName: 'SAIB',
      country: 'SA',
      locale: 'ar-SA',
      senderIds: ['saib', 'SAIB'],
      keywords: ['saib'],
      typeRules: {
        TransactionType.payment: ['شراء عبر نقاط البيع', 'شراء', 'نقاط البيع'],
        TransactionType.income: ['إيداع', 'credited'],
        TransactionType.transfer: ['تحويل'],
      },
      amountRules: ['مبلغ العملية:'],
      balanceRules: ['الرصيد المتاح:', 'المتاح'],
      feeRules: ['الرسوم:', 'رسوم العملية:'],
      merchantRules: ['اسم التاجر:', 'لدى:', 'At:'],
    ),
    BankProfile(
      bankKey: 'barq',
      displayName: 'barq',
      country: 'SA',
      locale: 'ar-SA',
      senderIds: ['barq', 'BARQ'],
      keywords: ['barq'],
      typeRules: {
        TransactionType.payment: [
          'POS International Purchase',
          'Purchase',
          'Online Purchase'
        ],
        TransactionType.transfer: ['transfer'],
        TransactionType.income: ['deposit', 'credited', 'Add'],
      },
      amountRules: ['Amount:'],
      balanceRules: ['Wallet balance:', 'Available Balance:', 'Balance:'],
      feeRules: ['Fee:'],
      merchantRules: ['At:'],
      currencyDecimals: 2,
    ),
    BankProfile(
      bankKey: 'stc_bank',
      displayName: 'STC Bank',
      country: 'SA',
      locale: 'ar-SA',
      senderIds: ['stcbank', 'STC-Bank', 'STCBank'],
      keywords: ['stc bank', 'stcbank'],
      typeRules: {
        TransactionType.payment: ['عملية انترنت', 'شراء'],
        TransactionType.transfer: [
          'Internal outward transfer',
          'حوالة داخلية صادرة',
          'حوالة'
        ],
        TransactionType.income: ['إضافة أموال', 'Add funds', 'إيداع'],
      },
      amountRules: ['Amount:', 'بـ:'],
      balanceRules: ['الرصيد:', 'Balance:'],
      merchantRules: ['To:', 'إلى:', 'من:'],
      fundingWallets: [],
    ),
    BankProfile(
      bankKey: 'anb',
      displayName: 'ANB',
      country: 'SA',
      locale: 'ar-SA',
      senderIds: ['anb', 'ANB'],
      keywords: ['anb'],
      typeRules: {
        TransactionType.governmentPayment: ['مدفوعات وزارة', 'الجهة:'],
        TransactionType.payment: ['مدفوعات', 'سداد', 'شراء'],
        TransactionType.income: ['إيداع', 'إيداع ATM'],
        TransactionType.transfer: ['تحويل', 'حوالة'],
      },
      amountRules: ['بـ:', 'بـ'],
      balanceRules: ['الرصيد:', 'الرصيد المتاح'],
      merchantRules: ['الجهة:', 'لدى:', 'At:'],
      preferredDateOrder: 'ymd',
    ),
    BankProfile(
      bankKey: 'bsf',
      displayName: 'BSF',
      country: 'SA',
      locale: 'ar-SA',
      senderIds: ['BSF', 'bsf', 'بنك فرنسا'],
      keywords: ['bsf', 'فرنسا'],
      typeRules: {
        TransactionType.payment: ['شراء عبر نقاط البيع', 'شراء'],
        TransactionType.transfer: ['تحويل'],
        TransactionType.income: ['إيداع'],
      },
      amountRules: ['بـ SAR', 'بـ'],
      balanceRules: ['الرصيد المتوفر:', 'الرصيد المتاح:'],
      feeRules: ['رسوم العملية:'],
      totalDueRules: ['المبلغ الإجمالي المستحق'],
      merchantRules: ['من ', 'لدى:', 'اسم التاجر:'],
    ),
    BankProfile(
      bankKey: 'albilad',
      displayName: 'بنك البلاد',
      country: 'SA',
      locale: 'ar-SA',
      senderIds: ['البلاد', 'albilad', 'AlBilad'],
      keywords: ['البلاد', 'albilad'],
      typeRules: {
        TransactionType.payment: ['مشتريات نقاط البيع', 'شراء'],
        TransactionType.income: ['إيداع', 'credited'],
        TransactionType.transfer: ['تحويل'],
      },
      amountRules: ['مبلغ:'],
      balanceRules: ['الرصيد المتاح:', 'الرصيد'],
      merchantRules: ['لدى:', 'اسم التاجر:'],
    ),
    BankProfile(
      bankKey: 'baj',
      displayName: 'بنك الجزيرة',
      country: 'SA',
      locale: 'ar-SA',
      senderIds: ['هذا الجزيرة', 'aljazira', 'AlJazira', 'BAJ'],
      keywords: ['الجزيرة', 'aljazira'],
      typeRules: {
        TransactionType.payment: [
          'معاملة التجارة الإلكترونية',
          'الشراء',
          'شراء'
        ],
        TransactionType.income: ['إيداع', 'credited'],
        TransactionType.transfer: ['تحويل'],
      },
      amountRules: ['بقيمة', 'مبلغ:'],
      balanceRules: ['الرصيد المتاح:', 'الرصيد'],
      merchantRules: ['لدى ', 'اسم التاجر:'],
    ),
    BankProfile(
      bankKey: 'dubai_bank',
      displayName: 'بنك دبي',
      country: 'AE',
      locale: 'ar-AE',
      senderIds: ['بنك دبي', 'dubai-bank', 'DubaiBank', 'EmiratesBank'],
      keywords: ['بنك دبي', 'dubai bank'],
      typeRules: {
        TransactionType.creditCardPayment: ['تأكيد السداد', 'بطاقة إئتمانية'],
        TransactionType.payment: ['شراء', 'purchase'],
        TransactionType.income: ['إيداع', 'credited'],
      },
      amountRules: ['مبلغ:'],
      balanceRules: ['رصيد:', 'الرصيد:'],
      merchantRules: ['لدى:', 'اسم التاجر:'],
      preferredDateOrder: 'dmy',
    ),
  ];

  /// كشف البنك من معرّف المرسِل أو نص الرسالة (best-effort).
  static BankProfile? detect(
    String normalizedText, {
    String? senderId,
    List<BankProfile> extraProfiles = const [],
  }) {
    final haystack = '${senderId ?? ''} $normalizedText'.toLowerCase();
    for (final profile in [...extraProfiles, ...all]) {
      for (final kw in [...profile.senderIds, ...profile.keywords]) {
        if (haystack.contains(kw.toLowerCase())) return profile;
      }
    }
    return null;
  }

  static BankProfile? findByKey(
    String bankKey, {
    List<BankProfile> extraProfiles = const [],
  }) {
    for (final profile in [...extraProfiles, ...all]) {
      if (profile.bankKey == bankKey) return profile;
    }
    return null;
  }
}
