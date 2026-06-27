import 'package:flutter/material.dart';

@immutable
class CouponOffer {
  const CouponOffer({
    required this.id,
    required this.partnerName,
    required this.title,
    required this.description,
    required this.code,
    required this.categoryLabel,
    required this.countryCodes,
    required this.validUntil,
    required this.accent,
    this.imageUrl,
    this.partnerUrl,
    this.featured = false,
  });

  final String id;
  final String partnerName;
  final String title;
  final String description;
  final String code;
  final String categoryLabel;
  final List<String> countryCodes;
  final DateTime validUntil;
  final Color accent;
  final String? imageUrl;
  final String? partnerUrl;
  final bool featured;

  bool get isExpired => validUntil.isBefore(DateTime.now());

  bool get expiresSoon {
    final remaining = validUntil.difference(DateTime.now());
    return !isExpired && remaining.inDays <= 7;
  }
}
