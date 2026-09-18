import 'package:flutter/widgets.dart';

import 'app_lucide_icons.dart';

/// The design system's category marks: **stroke icons**, one per category.
///
/// The prototype draws a category as `.icobox { background: var(--c-*-bg);
/// color: var(--c-*-ink) }` wrapping a 22px stroke `<svg>` — a tinted box with
/// a line-art glyph the tint colours. The app drew native colour emoji instead,
/// which carried their own colour, could not take the category ink, and read as
/// a different visual language from every other icon in the product.
///
/// The keys are the icon NAMES stored in `categories.icon` (Lucide spellings),
/// which is what `DatabaseSeed._iconFor` writes and what every call site
/// already passes around. Mapping at that layer rather than at the category key
/// means custom categories — which choose an icon name, not a category key —
/// resolve too.
///
/// Four names have no exact glyph in the bundled Lucide subset and take their
/// nearest true equivalent rather than a new codepoint: `car-taxi-front` → car,
/// `house` → home, `receipt-text` → receipt, `shopping-basket` → cart.
///
/// `category_icon_coverage_test` fails if any shipping category, any seeded
/// icon name, or any name this map claims to cover resolves to the fallback.
const Map<String, IconData> _categoryIcons = <String, IconData>{
  'utensils-crossed': AppLucideIcons.utensilsCrossed, // restaurants
  'shopping-basket': AppLucideIcons.shoppingCart, // groceries
  'car-taxi-front': AppLucideIcons.car, // transport
  'fuel': AppLucideIcons.fuel, // fuel
  'receipt-text': AppLucideIcons.receipt, // bills
  'shopping-bag': AppLucideIcons.shoppingBag, // shopping
  'heart-pulse': AppLucideIcons.heartPulse, // health
  'graduation-cap': AppLucideIcons.graduationCap, // education
  'clapperboard': AppLucideIcons.clapperboard, // entertainment
  'repeat': AppLucideIcons.repeat, // subscriptions
  'arrow-left-right': AppLucideIcons.arrowLeftRight, // transfers
  'banknote': AppLucideIcons.banknote, // cash
  'plane': AppLucideIcons.plane, // travel
  'gift': AppLucideIcons.gift, // gifts
  'baby': AppLucideIcons.baby, // kids
  'house': AppLucideIcons.home, // home
  'coffee': AppLucideIcons.coffee, // cafes
  'wrench': AppLucideIcons.wrench, // maintenance
  'cigarette': AppLucideIcons.cigarette, // smoking
  'dumbbell': AppLucideIcons.dumbbell, // fitness
  'scissors': AppLucideIcons.scissors, // beauty
  'heart-handshake': AppLucideIcons.heartHandshake, // charity
  'dog': AppLucideIcons.dog, // pets
  'shield-check': AppLucideIcons.shieldCheck, // insurance
  'piggy-bank': AppLucideIcons.piggyBank, // income
  'shapes': AppLucideIcons.shapes, // other
  'wallet-cards': AppLucideIcons.walletCards, // all expenses
  // Names reachable from custom categories and the category picker.
  'cake': AppLucideIcons.cake,
  'hotel': AppLucideIcons.hotel,
};

/// Icons whose meaning depends on reading direction, so they mirror in RTL.
///
/// Only the transfer arrow qualifies: it says "from here to there", and an
/// unmirrored one points the wrong way in Arabic. Everything else — a cup, a
/// plane, a cigarette — is an object, and objects do not flip.
const Set<String> _directionalIcons = <String>{'arrow-left-right'};

/// The glyph for an icon [name], or null when the map does not cover it.
///
/// Null rather than a silent fallback so the guard test can see a gap. The
/// renderer substitutes [fallbackCategoryIcon] at the last moment, which is a
/// rendering decision, not a mapping one.
IconData? categoryIconOrNull(String name) => _categoryIcons[name];

/// Shown only for a name no map covers — a custom category from a future
/// catalogue, say. It is still a stroke icon, so nothing ever falls back to a
/// different visual language.
const IconData fallbackCategoryIcon = AppLucideIcons.shapes;

bool categoryIconMirrors(String name) => _directionalIcons.contains(name);

/// Every name this map covers — the guard test reads it.
Iterable<String> get mappedCategoryIconNames => _categoryIcons.keys;
