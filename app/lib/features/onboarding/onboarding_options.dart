import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Holds the country/currency picked from the synced catalog during onboarding.
final onboardingSelectionProvider = StateProvider<OnboardingCountry?>(
  (_) => null,
);

/// Holds the date of birth picked during the first-run setup.
final onboardingDateOfBirthProvider = StateProvider<DateTime?>((_) => null);

/// Returns SMS filter keywords for a currency code.
List<String> currencyKeywords(String currencyCode) {
  switch (currencyCode.trim().toUpperCase()) {
    case 'SAR':
      return ['SAR', 'ريال', 'ر.س'];
    case 'AED':
      return ['AED', 'درهم', 'د.إ'];
    case 'EGP':
      return ['EGP', 'جنيه', 'ج.م'];
    case 'KWD':
      return ['KWD', 'دينار'];
    case 'QAR':
      return ['QAR', 'ريال'];
    case 'BHD':
      return ['BHD', 'دينار'];
    case 'OMR':
      return ['OMR', 'ريال'];
    case 'JOD':
      return ['JOD', 'دينار'];
    default:
      return [currencyCode.trim().toUpperCase()];
  }
}

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
