import 'package:flutter/material.dart';

class OnboardingCountry {
  const OnboardingCountry({
    required this.code,
    required this.name,
    required this.currency,
    required this.currencyCode,
  });

  final String code;
  final String name;
  final String currency;
  final String currencyCode;

  String localizedName(BuildContext context) {
    final locale = Localizations.localeOf(context).languageCode;
    if (locale == 'en') {
      return _enNames[code] ?? name;
    }
    return name;
  }

  String localizedCurrency(BuildContext context) {
    final locale = Localizations.localeOf(context).languageCode;
    if (locale == 'en') {
      return _enCurrencies[currencyCode] ?? currency;
    }
    return currency;
  }

  static const Map<String, String> _enNames = {
    'sa': 'Saudi Arabia',
    'ae': 'United Arab Emirates',
    'eg': 'Egypt',
    'kw': 'Kuwait',
    'qa': 'Qatar',
    'bh': 'Bahrain',
    'om': 'Oman',
    'jo': 'Jordan',
    'ps': 'Palestine',
    'lb': 'Lebanon',
    'ly': 'Libya',
    'sy': 'Syria',
    'ma': 'Morocco',
    'mr': 'Mauritania',
    'dz': 'Algeria',
    'tn': 'Tunisia',
    'sd': 'Sudan',
    'iq': 'Iraq',
    'ye': 'Yemen',
    'so': 'Somalia',
    'dj': 'Djibouti',
    'km': 'Comoros',
    'tr': 'Turkey',
    'us': 'United States',
    'gb': 'United Kingdom',
    'eu': 'Eurozone',
    'in': 'India',
    'pk': 'Pakistan',
    'bd': 'Bangladesh',
    'ph': 'Philippines',
    'id': 'Indonesia',
    'my': 'Malaysia',
    'sg': 'Singapore',
    'ng': 'Nigeria',
    'ke': 'Kenya',
    'za': 'South Africa',
    'et': 'Ethiopia',
    'gh': 'Ghana',
    'ug': 'Uganda',
    'tz': 'Tanzania',
  };

  static const Map<String, String> _enCurrencies = {
    'SAR': 'Saudi Riyal',
    'AED': 'UAE Dirham',
    'EGP': 'Egyptian Pound',
    'KWD': 'Kuwaiti Dinar',
    'QAR': 'Qatari Riyal',
    'BHD': 'Bahraini Dinar',
    'OMR': 'Omani Riyal',
    'JOD': 'Jordanian Dinar',
    'ILS': 'Israeli Shekel',
    'LBP': 'Lebanese Pound',
    'LYD': 'Libyan Dinar',
    'SYP': 'Syrian Pound',
    'MAD': 'Moroccan Dirham',
    'MRU': 'Mauritanian Ouguiya',
    'DZD': 'Algerian Dinar',
    'TND': 'Tunisian Dinar',
    'SDG': 'Sudanese Pound',
    'IQD': 'Iraqi Dinar',
    'YER': 'Yemeni Rial',
    'SOS': 'Somali Shilling',
    'DJF': 'Djiboutian Franc',
    'KMF': 'Comorian Franc',
    'TRY': 'Turkish Lira',
    'USD': 'US Dollar',
    'GBP': 'British Pound',
    'EUR': 'Euro',
    'INR': 'Indian Rupee',
    'PKR': 'Pakistani Rupee',
    'BDT': 'Bangladeshi Taka',
    'PHP': 'Philippine Peso',
    'IDR': 'Indonesian Rupiah',
    'MYR': 'Malaysian Ringgit',
    'SGD': 'Singapore Dollar',
    'NGN': 'Nigerian Naira',
    'KES': 'Kenyan Shilling',
    'ZAR': 'South African Rand',
    'ETB': 'Ethiopian Birr',
    'GHS': 'Ghanaian Cedi',
    'UGX': 'Ugandan Shilling',
    'TZS': 'Tanzanian Shilling',
  };
}

class OnboardingCurrency {
  const OnboardingCurrency({
    required this.code,
    required this.name,
  });

  final String code;
  final String name;

  String localizedName(BuildContext context) {
    final locale = Localizations.localeOf(context).languageCode;
    if (locale == 'en') {
      return _enNames[code] ?? name;
    }
    return name;
  }

  static const Map<String, String> _enNames = {
    'USD': 'US Dollar',
    'EUR': 'Euro',
    'GBP': 'British Pound',
    'AED': 'UAE Dirham',
    'SAR': 'Saudi Riyal',
    'EGP': 'Egyptian Pound',
    'KWD': 'Kuwaiti Dinar',
    'QAR': 'Qatari Riyal',
    'BHD': 'Bahraini Dinar',
    'OMR': 'Omani Riyal',
    'JOD': 'Jordanian Dinar',
    'TRY': 'Turkish Lira',
    'INR': 'Indian Rupee',
    'PHP': 'Philippine Peso',
  };
}

class SubscriptionShowcase {
  const SubscriptionShowcase({
    required this.name,
    required this.asset,
    required this.priceAr,
    required this.priceEn,
    required this.brandColor,
  });

  final String name;
  final String asset;
  final String priceAr;
  final String priceEn;
  final Color brandColor;

  String localizedPrice(BuildContext context) {
    final locale = Localizations.localeOf(context).languageCode;
    return locale == 'en' ? priceEn : priceAr;
  }
}

const onboardingCountries = [
  OnboardingCountry(code: 'sa', name: 'السعودية', currency: 'ريال سعودي', currencyCode: 'SAR'),
  OnboardingCountry(code: 'ae', name: 'الإمارات', currency: 'درهم إماراتي', currencyCode: 'AED'),
  OnboardingCountry(code: 'eg', name: 'مصر', currency: 'جنيه مصري', currencyCode: 'EGP'),
  OnboardingCountry(code: 'kw', name: 'الكويت', currency: 'دينار كويتي', currencyCode: 'KWD'),
  OnboardingCountry(code: 'qa', name: 'قطر', currency: 'ريال قطري', currencyCode: 'QAR'),
  OnboardingCountry(code: 'bh', name: 'البحرين', currency: 'دينار بحريني', currencyCode: 'BHD'),
  OnboardingCountry(code: 'om', name: 'عمان', currency: 'ريال عماني', currencyCode: 'OMR'),
  OnboardingCountry(code: 'jo', name: 'الأردن', currency: 'دينار أردني', currencyCode: 'JOD'),
  OnboardingCountry(code: 'ps', name: 'فلسطين', currency: 'شيكل إسرائيلي', currencyCode: 'ILS'),
  OnboardingCountry(code: 'lb', name: 'لبنان', currency: 'ليرة لبنانية', currencyCode: 'LBP'),
  OnboardingCountry(code: 'ly', name: 'ليبيا', currency: 'دينار ليبي', currencyCode: 'LYD'),
  OnboardingCountry(code: 'sy', name: 'سوريا', currency: 'ليرة سورية', currencyCode: 'SYP'),
  OnboardingCountry(code: 'ma', name: 'المغرب', currency: 'درهم مغربي', currencyCode: 'MAD'),
  OnboardingCountry(code: 'mr', name: 'موريتانيا', currency: 'أوقية موريتانية', currencyCode: 'MRU'),
  OnboardingCountry(code: 'dz', name: 'الجزائر', currency: 'دينار جزائري', currencyCode: 'DZD'),
  OnboardingCountry(code: 'tn', name: 'تونس', currency: 'دينار تونسي', currencyCode: 'TND'),
  OnboardingCountry(code: 'sd', name: 'السودان', currency: 'جنيه سوداني', currencyCode: 'SDG'),
  OnboardingCountry(code: 'iq', name: 'العراق', currency: 'دينار عراقي', currencyCode: 'IQD'),
  OnboardingCountry(code: 'ye', name: 'اليمن', currency: 'ريال يمني', currencyCode: 'YER'),
  OnboardingCountry(code: 'so', name: 'الصومال', currency: 'شلن صومالي', currencyCode: 'SOS'),
  OnboardingCountry(code: 'dj', name: 'جيبوتي', currency: 'فرنك جيبوتي', currencyCode: 'DJF'),
  OnboardingCountry(code: 'km', name: 'جزر القمر', currency: 'فرنك قمري', currencyCode: 'KMF'),
  OnboardingCountry(code: 'tr', name: 'تركيا', currency: 'ليرة تركية', currencyCode: 'TRY'),
  OnboardingCountry(code: 'us', name: 'الولايات المتحدة', currency: 'دولار أمريكي', currencyCode: 'USD'),
  OnboardingCountry(code: 'gb', name: 'المملكة المتحدة', currency: 'جنيه إسترليني', currencyCode: 'GBP'),
  OnboardingCountry(code: 'eu', name: 'منطقة اليورو', currency: 'يورو', currencyCode: 'EUR'),
  OnboardingCountry(code: 'in', name: 'الهند', currency: 'روبية هندية', currencyCode: 'INR'),
  OnboardingCountry(code: 'pk', name: 'باكستان', currency: 'روبية باكستانية', currencyCode: 'PKR'),
  OnboardingCountry(code: 'bd', name: 'بنغلاديش', currency: 'تاكا بنغلاديشي', currencyCode: 'BDT'),
  OnboardingCountry(code: 'ph', name: 'الفلبين', currency: 'بيزو فلبيني', currencyCode: 'PHP'),
  OnboardingCountry(code: 'id', name: 'إندونيسيا', currency: 'روبية إندونيسية', currencyCode: 'IDR'),
  OnboardingCountry(code: 'my', name: 'ماليزيا', currency: 'رينغيت ماليزي', currencyCode: 'MYR'),
  OnboardingCountry(code: 'sg', name: 'سنغافورة', currency: 'دولار سنغافوري', currencyCode: 'SGD'),
  OnboardingCountry(code: 'ng', name: 'نيجيريا', currency: 'نايرا نيجيرية', currencyCode: 'NGN'),
  OnboardingCountry(code: 'ke', name: 'كينيا', currency: 'شلن كيني', currencyCode: 'KES'),
  OnboardingCountry(code: 'za', name: 'جنوب أفريقيا', currency: 'راند جنوب أفريقي', currencyCode: 'ZAR'),
  OnboardingCountry(code: 'et', name: 'إثيوبيا', currency: 'بير إثيوبي', currencyCode: 'ETB'),
  OnboardingCountry(code: 'gh', name: 'غانا', currency: 'سيدي غاني', currencyCode: 'GHS'),
  OnboardingCountry(code: 'ug', name: 'أوغندا', currency: 'شلن أوغندي', currencyCode: 'UGX'),
  OnboardingCountry(code: 'tz', name: 'تنزانيا', currency: 'شلن تنزاني', currencyCode: 'TZS'),
];

const onboardingCurrencies = [
  OnboardingCurrency(code: 'USD', name: 'دولار أمريكي'),
  OnboardingCurrency(code: 'EUR', name: 'يورو'),
  OnboardingCurrency(code: 'GBP', name: 'جنيه إسترليني'),
  OnboardingCurrency(code: 'AED', name: 'درهم إماراتي'),
  OnboardingCurrency(code: 'SAR', name: 'ريال سعودي'),
  OnboardingCurrency(code: 'EGP', name: 'جنيه مصري'),
  OnboardingCurrency(code: 'KWD', name: 'دينار كويتي'),
  OnboardingCurrency(code: 'QAR', name: 'ريال قطري'),
  OnboardingCurrency(code: 'BHD', name: 'دينار بحريني'),
  OnboardingCurrency(code: 'OMR', name: 'ريال عماني'),
  OnboardingCurrency(code: 'JOD', name: 'دينار أردني'),
  OnboardingCurrency(code: 'TRY', name: 'ليرة تركية'),
  OnboardingCurrency(code: 'INR', name: 'روبية هندية'),
  OnboardingCurrency(code: 'PHP', name: 'بيزو فلبيني'),
];

const subscriptionShowcase = [
  SubscriptionShowcase(
    name: 'Netflix',
    asset: 'netflix',
    priceAr: '39 ريال شهرياً',
    priceEn: '39 SAR / month',
    brandColor: Color(0xFFE50914),
  ),
  SubscriptionShowcase(
    name: 'Spotify',
    asset: 'spotify',
    priceAr: '22 ريال شهرياً',
    priceEn: '22 SAR / month',
    brandColor: Color(0xFF1DB954),
  ),
  SubscriptionShowcase(
    name: 'YouTube',
    asset: 'youtube',
    priceAr: '24 ريال شهرياً',
    priceEn: '24 SAR / month',
    brandColor: Color(0xFFFF0000),
  ),
  SubscriptionShowcase(
    name: 'Apple',
    asset: 'apple',
    priceAr: '19 ريال شهرياً',
    priceEn: '19 SAR / month',
    brandColor: Color(0xFF111111),
  ),
];
