import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import 'coupon_models.dart';

final couponsProvider = FutureProvider<List<CouponOffer>>((ref) async {
  final settings = await ref.watch(loadUserSettingsUseCaseProvider).call();
  final country = settings.country.trim().toUpperCase();
  final now = DateTime.now();
  return couponsForCountry(_sampleCoupons(now), country);
});

final dashboardCouponsProvider = Provider<AsyncValue<List<CouponOffer>>>((ref) {
  final async = ref.watch(couponsProvider);
  return async.whenData((offers) => offers.take(3).toList(growable: false));
});

List<CouponOffer> _sampleCoupons(DateTime now) {
  return [
    CouponOffer(
      id: 'qirsh-food-20',
      partnerName: 'Talabat',
      title: 'خصم 20% على أول طلب',
      description: 'استخدم الكود قبل الدفع ووفر على طلبات المطاعم والتوصيل.',
      code: 'QIRSH20',
      categoryLabel: 'مطاعم وتوصيل',
      countryCodes: const ['EG', 'SA', 'AE'],
      validUntil: now.add(const Duration(days: 12)),
      accent: const Color(0xFFFF6B35),
      partnerUrl: 'https://www.talabat.com',
      featured: true,
    ),
    CouponOffer(
      id: 'qirsh-grocery-15',
      partnerName: 'Carrefour',
      title: 'وفر 15% على مشتريات البيت',
      description:
          'عرض تجريبي للكوبونات داخل قرش، قابل للاستبدال بشركاء حقيقيين.',
      code: 'SAVE15',
      categoryLabel: 'سوبر ماركت',
      countryCodes: const ['EG', 'SA', 'AE'],
      validUntil: now.add(const Duration(days: 5)),
      accent: const Color(0xFF2563EB),
      partnerUrl: 'https://www.carrefour.com',
    ),
    CouponOffer(
      id: 'qirsh-streaming-10',
      partnerName: 'Spotify',
      title: 'شهر موسيقى بتكلفة أقل',
      description: 'مناسب لو عندك اشتراكات شهرية وعايز تقلل الصرف المتكرر.',
      code: 'QIRSHMUSIC',
      categoryLabel: 'اشتراكات',
      countryCodes: const ['ALL'],
      validUntil: now.add(const Duration(days: 20)),
      accent: const Color(0xFF1DB954),
      partnerUrl: 'https://www.spotify.com',
    ),
    CouponOffer(
      id: 'qirsh-fashion-25',
      partnerName: 'Zara',
      title: 'خصم موسمي 25%',
      description: 'استخدم الكوبون وقت الشراء وخلي قرش يحسب التوفير معاك.',
      code: 'STYLE25',
      categoryLabel: 'تسوق',
      countryCodes: const ['EG', 'SA', 'AE'],
      validUntil: now.add(const Duration(days: 30)),
      accent: const Color(0xFF111827),
      partnerUrl: 'https://www.zara.com',
    ),
  ];
}

List<CouponOffer> couponsForCountry(
  List<CouponOffer> offers,
  String countryCode,
) {
  final country = countryCode.trim().toUpperCase();
  return offers
      .where((offer) =>
          !offer.isExpired &&
          (offer.countryCodes.contains('ALL') ||
              offer.countryCodes.contains(country)))
      .toList()
    ..sort((a, b) {
      if (a.featured != b.featured) return a.featured ? -1 : 1;
      if (a.expiresSoon != b.expiresSoon) return a.expiresSoon ? -1 : 1;
      return a.validUntil.compareTo(b.validUntil);
    });
}
