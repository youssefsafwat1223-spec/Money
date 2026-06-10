import 'package:flutter/widgets.dart';

import 'app_lucide_icons.dart';

/// يحوّل اسم أيقونة Lucide (نصّي، كما يُخزَّن في DB) إلى [IconData].
IconData lucideByName(String name) {
  switch (name) {
    case 'utensils-crossed':
      return AppLucideIcons.utensilsCrossed;
    case 'shopping-basket':
      return AppLucideIcons.shoppingCart;
    case 'car-taxi-front':
      return AppLucideIcons.car;
    case 'fuel':
      return AppLucideIcons.fuel;
    case 'receipt-text':
      return AppLucideIcons.receipt;
    case 'shopping-bag':
      return AppLucideIcons.shoppingBag;
    case 'heart-pulse':
      return AppLucideIcons.heartPulse;
    case 'graduation-cap':
      return AppLucideIcons.graduationCap;
    case 'clapperboard':
      return AppLucideIcons.clapperboard;
    case 'repeat':
      return AppLucideIcons.repeat;
    case 'arrow-left-right':
      return AppLucideIcons.arrowLeftRight;
    case 'banknote':
      return AppLucideIcons.banknote;
    case 'plane':
      return AppLucideIcons.plane;
    case 'gift':
      return AppLucideIcons.gift;
    case 'baby':
      return AppLucideIcons.baby;
    case 'house':
      return AppLucideIcons.home;
    case 'coffee':
      return AppLucideIcons.coffee;
    case 'wrench':
      return AppLucideIcons.wrench;
    case 'wallet-cards':
      return AppLucideIcons.walletCards;
    case 'shapes':
    default:
      return AppLucideIcons.shapes;
  }
}
