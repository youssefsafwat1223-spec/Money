import '../models/transaction_source.dart';
import '../models/transaction_type.dart';

String _compactBankToken(String input) =>
    input.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\u0600-\u06ff]+'), '');

bool _matchesBankAlias(
    String rawHaystack, String compactHaystack, String alias) {
  final rawAlias = alias.trim().toLowerCase();
  if (rawAlias.isEmpty) return false;
  final compactAlias = _compactBankToken(alias);
  if (compactAlias.isEmpty) return false;
  return rawHaystack.contains(rawAlias) ||
      compactHaystack.contains(compactAlias);
}

bool _matchesSenderAlias(String rawSender, String compactSender, String alias) {
  final compactAlias = _compactBankToken(alias);
  if (compactAlias.isEmpty) return false;
  final parts = rawSender
      .split(RegExp(r'[^a-z0-9\u0600-\u06ff]+'))
      .map(_compactBankToken)
      .where((part) => part.isNotEmpty);
  return compactSender == compactAlias ||
      compactSender.startsWith(compactAlias) ||
      parts.contains(compactAlias);
}

/// ملف تعريف بنك/محفظة (P0 للسوق السعودي).
///
/// هذا هيكل مبدئي: الكشف عبر كلمات مفتاحية في النص أو معرّف المرسِل.
/// Codex يوسّعه بقواعد regex لكل بنك من docs/specs/SAUDI_MARKET_SPEC.md وبقاعدة
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
    final compactSender = _compactBankToken(sender);
    return [...senderIds, ...keywords].any(
      (item) => _matchesSenderAlias(sender, compactSender, item),
    );
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
      senderIds: [
        'cib',
        'cib alerts',
        'cibalerts',
        'cibbank',
        'cibeg',
      ],
      keywords: ['cib', 'commercial international bank', 'التجاري الدولي'],
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
      senderIds: [
        'nbe',
        'NBE',
        'nbe alerts',
        'nbealerts',
        'ahlybank',
        'AlAhlyBank',
        'alahlybank',
        'natbank',
        'nbebank',
      ],
      keywords: ['nbe', 'الأهلي المصري', 'national bank of egypt'],
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
      senderIds: ['banquemisr', 'banque misr', 'bm', 'bmisr', 'misrbank'],
      keywords: ['بنك مصر', 'banquemisr', 'banque misr'],
      typeRules: {
        TransactionType.payment: ['خصم'],
        TransactionType.income: ['إيداع', 'ايداع', 'credited'],
      },
      balanceRules: ['المتاح', 'الرصيد'],
      merchantRules: ['عند', 'لدى'],
    ),
    BankProfile(
      bankKey: 'qnb_alahli',
      displayName: 'QNB الأهلي',
      country: 'EG',
      locale: 'ar-EG',
      senderIds: ['qnb', 'qnba', 'qnbalahli', 'qnb alahli', 'qnb-al-ahli'],
      keywords: ['qnb', 'qnb al ahli', 'qnb الأهلي'],
      typeRules: {
        TransactionType.payment: ['خصم', 'debit', 'purchase', 'شراء'],
        TransactionType.income: ['إيداع', 'ايداع', 'credited', 'credit'],
        TransactionType.withdrawal: ['سحب', 'atm', 'withdrawal'],
        TransactionType.transfer: ['تحويل', 'transfer'],
      },
      balanceRules: ['المتاح', 'الرصيد', 'available', 'balance'],
      merchantRules: ['عند', 'لدى', 'at'],
    ),
    BankProfile(
      bankKey: 'bdc_eg',
      displayName: 'بنك القاهرة',
      country: 'EG',
      locale: 'ar-EG',
      senderIds: ['bdc', 'bdcbank', 'banqueducaire', 'banque du caire'],
      keywords: ['بنك القاهرة', 'banque du caire', 'bdc'],
      typeRules: {
        TransactionType.payment: ['خصم', 'debit', 'purchase', 'شراء'],
        TransactionType.income: ['إيداع', 'ايداع', 'credited', 'credit'],
        TransactionType.withdrawal: ['سحب', 'atm', 'withdrawal'],
        TransactionType.transfer: ['تحويل', 'transfer'],
      },
      balanceRules: ['المتاح', 'الرصيد', 'available', 'balance'],
      merchantRules: ['عند', 'لدى', 'at'],
    ),
    BankProfile(
      bankKey: 'alexbank_eg',
      displayName: 'بنك الإسكندرية',
      country: 'EG',
      locale: 'ar-EG',
      senderIds: ['alexbank', 'boalex', 'bankofalexandria'],
      keywords: ['بنك الإسكندرية', 'بنك الاسكندرية', 'alexbank'],
      typeRules: {
        TransactionType.payment: ['خصم', 'debit', 'purchase', 'شراء'],
        TransactionType.income: ['إيداع', 'ايداع', 'credited', 'credit'],
        TransactionType.withdrawal: ['سحب', 'atm', 'withdrawal'],
        TransactionType.transfer: ['تحويل', 'transfer'],
      },
      balanceRules: ['المتاح', 'الرصيد', 'available', 'balance'],
      merchantRules: ['عند', 'لدى', 'at'],
    ),
    BankProfile(
      bankKey: 'aaib_eg',
      displayName: 'البنك العربي الإفريقي',
      country: 'EG',
      locale: 'ar-EG',
      senderIds: ['aaib', 'arabafrican', 'arabafricanbank'],
      keywords: ['العربي الإفريقي', 'العربي الافريقي', 'aaib'],
      typeRules: {
        TransactionType.payment: ['خصم', 'debit', 'purchase', 'شراء'],
        TransactionType.income: ['إيداع', 'ايداع', 'credited', 'credit'],
        TransactionType.withdrawal: ['سحب', 'atm', 'withdrawal'],
        TransactionType.transfer: ['تحويل', 'transfer'],
      },
      balanceRules: ['المتاح', 'الرصيد', 'available', 'balance'],
      merchantRules: ['عند', 'لدى', 'at'],
    ),
    BankProfile(
      bankKey: 'hdb_eg',
      displayName: 'بنك التعمير والإسكان',
      country: 'EG',
      locale: 'ar-EG',
      senderIds: ['hdb', 'hdbank'],
      keywords: ['بنك التعمير', 'بنك الاسكان', 'hdb'],
      typeRules: {
        TransactionType.payment: ['خصم', 'debit', 'purchase', 'شراء'],
        TransactionType.income: ['إيداع', 'ايداع', 'credited', 'credit'],
        TransactionType.withdrawal: ['سحب', 'atm', 'withdrawal'],
        TransactionType.transfer: ['تحويل', 'transfer'],
      },
      balanceRules: ['المتاح', 'الرصيد', 'available', 'balance'],
      merchantRules: ['عند', 'لدى', 'at'],
    ),
    BankProfile(
      bankKey: 'faisal_eg',
      displayName: 'بنك فيصل الإسلامي',
      country: 'EG',
      locale: 'ar-EG',
      senderIds: ['faisalbank', 'fib', 'fibeg'],
      keywords: ['بنك فيصل', 'faisal bank', 'fib'],
      typeRules: {
        TransactionType.payment: ['خصم', 'debit', 'purchase', 'شراء'],
        TransactionType.income: ['إيداع', 'ايداع', 'credited', 'credit'],
        TransactionType.withdrawal: ['سحب', 'atm', 'withdrawal'],
        TransactionType.transfer: ['تحويل', 'transfer'],
      },
      balanceRules: ['المتاح', 'الرصيد', 'available', 'balance'],
      merchantRules: ['عند', 'لدى', 'at'],
    ),
    BankProfile(
      bankKey: 'instapay_eg',
      displayName: 'InstaPay',
      country: 'EG',
      locale: 'ar-EG',
      senderIds: ['ipn', 'instapay'],
      keywords: ['ipn', 'instapay'],
      typeRules: {
        TransactionType.transfer: ['transfer', 'تحويل'],
        TransactionType.income: ['received', 'incoming', 'استلام'],
      },
      amountRules: ['amount', 'مبلغ'],
      dateRules: ['on', 'في'],
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
    // ── UAE banks ────────────────────────────────────────────────────────────
    BankProfile(
      bankKey: 'adib',
      displayName: 'مصرف أبوظبي الإسلامي',
      country: 'AE',
      locale: 'ar-AE',
      senderIds: ['adib', 'ADIB', 'AbuDhabiIslamicBank'],
      keywords: ['adib', 'أبوظبي الإسلامي', 'abu dhabi islamic'],
      typeRules: {
        TransactionType.payment: [
          'تم الخصم',
          'debit',
          'purchase',
          'spent',
          'شراء'
        ],
        TransactionType.income: ['تم الإيداع', 'credited', 'credit', 'إيداع'],
        TransactionType.transfer: ['تحويل', 'transfer'],
        TransactionType.withdrawal: ['سحب', 'withdrawal', 'atm'],
      },
      amountRules: ['مبلغ:', 'amount:', 'بـ'],
      balanceRules: ['الرصيد المتاح', 'available balance', 'balance:'],
      merchantRules: ['لدى', 'at', 'merchant:'],
      preferredDateOrder: 'dmy',
      currencyAliases: {'د.إ': 'AED'},
    ),
    BankProfile(
      bankKey: 'adcb',
      displayName: 'بنك أبوظبي التجاري',
      country: 'AE',
      locale: 'ar-AE',
      senderIds: ['adcb', 'ADCB', 'AbuDhabiCommercialBank'],
      keywords: ['adcb', 'أبوظبي التجاري', 'abu dhabi commercial'],
      typeRules: {
        TransactionType.payment: ['debit', 'purchase', 'شراء', 'خصم'],
        TransactionType.income: ['credit', 'credited', 'إيداع'],
        TransactionType.transfer: ['transfer', 'تحويل'],
        TransactionType.withdrawal: ['withdrawal', 'atm', 'cash', 'سحب'],
      },
      amountRules: ['amount', 'amt', 'مبلغ'],
      balanceRules: ['available balance', 'avail bal', 'الرصيد المتاح'],
      merchantRules: ['at', 'merchant', 'لدى'],
      preferredDateOrder: 'dmy',
      currencyAliases: {'د.إ': 'AED'},
    ),
    BankProfile(
      bankKey: 'fab',
      displayName: 'بنك أبوظبي الأول',
      country: 'AE',
      locale: 'ar-AE',
      senderIds: ['fab', 'FAB', 'FirstAbuDhabi', 'first-abu-dhabi'],
      keywords: ['fab', 'first abu dhabi', 'بنك أبوظبي الأول'],
      typeRules: {
        TransactionType.payment: ['debit', 'purchase', 'خصم', 'شراء'],
        TransactionType.income: ['credit', 'credited', 'إيداع', 'salary'],
        TransactionType.transfer: ['transfer', 'تحويل'],
        TransactionType.withdrawal: ['atm', 'cash withdrawal', 'سحب'],
      },
      amountRules: ['amount', 'مبلغ'],
      balanceRules: ['balance', 'avail', 'الرصيد'],
      merchantRules: ['at', 'merchant', 'لدى'],
      preferredDateOrder: 'dmy',
      currencyAliases: {'د.إ': 'AED'},
    ),
    BankProfile(
      bankKey: 'enbd',
      displayName: 'بنك الإمارات دبي الوطني',
      country: 'AE',
      locale: 'ar-AE',
      senderIds: ['enbd', 'ENBD', 'EmiratesNBD', 'Emirates-NBD'],
      keywords: ['enbd', 'emirates nbd', 'الإمارات دبي الوطني'],
      typeRules: {
        TransactionType.payment: ['debit', 'purchase', 'خصم', 'pos'],
        TransactionType.income: ['credit', 'credited', 'إيداع'],
        TransactionType.transfer: ['transfer', 'تحويل'],
        TransactionType.withdrawal: ['atm', 'cash', 'سحب'],
        TransactionType.creditCardPayment: ['payment received', 'bill payment'],
      },
      amountRules: ['amount', 'amt', 'مبلغ'],
      balanceRules: ['available balance', 'bal', 'الرصيد'],
      merchantRules: ['at', 'merchant', 'لدى'],
      preferredDateOrder: 'dmy',
      currencyAliases: {'د.إ': 'AED', 'aed': 'AED'},
    ),
    BankProfile(
      bankKey: 'mashreq',
      displayName: 'بنك المشرق',
      country: 'AE',
      locale: 'ar-AE',
      senderIds: ['mashreq', 'Mashreq', 'MashreqBank'],
      keywords: ['mashreq', 'المشرق'],
      typeRules: {
        TransactionType.payment: ['debit', 'purchase', 'خصم', 'spent'],
        TransactionType.income: ['credit', 'credited', 'إيداع'],
        TransactionType.transfer: ['transfer', 'تحويل'],
        TransactionType.withdrawal: ['atm', 'cash withdrawal', 'سحب'],
      },
      amountRules: ['amount', 'مبلغ'],
      balanceRules: ['available', 'balance', 'الرصيد'],
      merchantRules: ['at', 'لدى'],
      preferredDateOrder: 'dmy',
      currencyAliases: {'د.إ': 'AED'},
    ),
  ];

  /// كشف البنك من معرّف المرسِل أو نص الرسالة (best-effort).
  static BankProfile? detect(
    String normalizedText, {
    String? senderId,
    List<BankProfile> extraProfiles = const [],
  }) {
    final text = normalizedText.toLowerCase();
    final compactText = _compactBankToken(text);
    for (final profile in [...extraProfiles, ...all]) {
      if (profile.matchesSender(senderId)) return profile;
    }
    for (final profile in [...extraProfiles, ...all]) {
      final matched = [...profile.senderIds, ...profile.keywords].any(
        (item) => _matchesBankAlias(text, compactText, item),
      );
      if (matched) return profile;
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
