import 'formatters.dart';

/// مصدر واحد لاسم/رمز العملة وتنسيق المبالغ — يمنع تضارب «ريال/جنيه» الثابتة.
class Currency {
  Currency._();

  /// الاسم العربي المختصر للعملة حسب رمز ISO. يغطّي كل الدول المدعومة.
  static String arabicLabel(String code) => switch (code.toUpperCase()) {
        'SAR' => 'ريال',
        'AED' => 'درهم',
        'EGP' => 'جنيه',
        'KWD' => 'دينار',
        'QAR' => 'ريال قطري',
        'BHD' => 'دينار بحريني',
        'OMR' => 'ريال عماني',
        'JOD' => 'دينار أردني',
        'ILS' => 'شيكل',
        'LBP' => 'ليرة لبنانية',
        'LYD' => 'دينار ليبي',
        'SYP' => 'ليرة سورية',
        'MAD' => 'درهم مغربي',
        'MRU' => 'أوقية',
        'DZD' => 'دينار جزائري',
        'TND' => 'دينار تونسي',
        'SDG' => 'جنيه سوداني',
        'IQD' => 'دينار عراقي',
        'YER' => 'ريال يمني',
        'SOS' => 'شلن صومالي',
        'DJF' => 'فرنك جيبوتي',
        'KMF' => 'فرنك قمري',
        'TRY' => 'ليرة تركية',
        'USD' => 'دولار',
        'EUR' => 'يورو',
        'GBP' => 'جنيه إسترليني',
        'INR' => 'روبية',
        'PKR' => 'روبية باكستانية',
        'BDT' => 'تاكا',
        'PHP' => 'بيزو',
        'IDR' => 'روبية إندونيسية',
        'MYR' => 'رينغيت',
        'SGD' => 'دولار سنغافوري',
        'NGN' => 'نايرا',
        'KES' => 'شلن كيني',
        'ZAR' => 'راند',
        'ETB' => 'بير',
        'GHS' => 'سيدي',
        'UGX' => 'شلن أوغندي',
        'TZS' => 'شلن تنزاني',
        _ => code.toUpperCase(),
      };

  /// "1,240.00 ريال"
  static String money(double amount, String code) =>
      '${Formatters.amount(amount)} ${arabicLabel(code)}';

  /// "1,240 ريال" (بدون كسور)
  static String moneyInt(num amount, String code) =>
      '${Formatters.integer(amount)} ${arabicLabel(code)}';
}
