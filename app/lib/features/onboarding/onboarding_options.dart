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
}

class OnboardingCurrency {
  const OnboardingCurrency({
    required this.code,
    required this.name,
  });

  final String code;
  final String name;
}

class SubscriptionShowcase {
  const SubscriptionShowcase({
    required this.name,
    required this.asset,
    required this.price,
    required this.brandColor,
  });

  final String name;
  final String asset;
  final String price;
  final Color brandColor;
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
    price: '39 ريال شهرياً',
    brandColor: Color(0xFFE50914),
  ),
  SubscriptionShowcase(
    name: 'Spotify',
    asset: 'spotify',
    price: '22 ريال شهرياً',
    brandColor: Color(0xFF1DB954),
  ),
  SubscriptionShowcase(
    name: 'YouTube',
    asset: 'youtube',
    price: '24 ريال شهرياً',
    brandColor: Color(0xFFFF0000),
  ),
  SubscriptionShowcase(
    name: 'Apple',
    asset: 'apple',
    price: '19 ريال شهرياً',
    brandColor: Color(0xFF111111),
  ),
];
