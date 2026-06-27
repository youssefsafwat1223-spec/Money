import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/coupons/coupon_models.dart';
import 'package:money_companion/features/coupons/coupons_providers.dart';

void main() {
  test('couponsForCountry filters expired and country-specific offers', () {
    final now = DateTime.now();
    final offers = [
      CouponOffer(
        id: 'eg',
        partnerName: 'Partner EG',
        title: 'EG',
        description: 'EG',
        code: 'EG',
        categoryLabel: 'test',
        countryCodes: const ['EG'],
        validUntil: now.add(const Duration(days: 3)),
        accent: Colors.blue,
      ),
      CouponOffer(
        id: 'sa',
        partnerName: 'Partner SA',
        title: 'SA',
        description: 'SA',
        code: 'SA',
        categoryLabel: 'test',
        countryCodes: const ['SA'],
        validUntil: now.add(const Duration(days: 3)),
        accent: Colors.green,
      ),
      CouponOffer(
        id: 'expired',
        partnerName: 'Expired',
        title: 'Expired',
        description: 'Expired',
        code: 'OLD',
        categoryLabel: 'test',
        countryCodes: const ['ALL'],
        validUntil: now.subtract(const Duration(days: 1)),
        accent: Colors.red,
      ),
    ];

    final result = couponsForCountry(offers, 'EG');

    expect(result.map((offer) => offer.id), ['eg']);
  });

  test('couponsForCountry puts featured offers first', () {
    final now = DateTime.now();
    final offers = [
      CouponOffer(
        id: 'normal',
        partnerName: 'Normal',
        title: 'Normal',
        description: 'Normal',
        code: 'NORMAL',
        categoryLabel: 'test',
        countryCodes: const ['ALL'],
        validUntil: now.add(const Duration(days: 1)),
        accent: Colors.blue,
      ),
      CouponOffer(
        id: 'featured',
        partnerName: 'Featured',
        title: 'Featured',
        description: 'Featured',
        code: 'FEATURED',
        categoryLabel: 'test',
        countryCodes: const ['ALL'],
        validUntil: now.add(const Duration(days: 20)),
        accent: Colors.amber,
        featured: true,
      ),
    ];

    final result = couponsForCountry(offers, 'EG');

    expect(result.first.id, 'featured');
  });
}
