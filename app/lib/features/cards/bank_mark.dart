import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../domain/entities/account_entity.dart';

/// Bank logo widget — colored rounded square + abbreviation for banks without
/// a bundled SVG asset. Falls back to the account-type icon when no bank match.
class BankMark extends StatelessWidget {
  const BankMark({
    super.key,
    required this.accountName,
    required this.accountType,
    this.size = 46,
  });

  final String accountName;
  final AccountType accountType;
  final double size;

  // short_code → (brandColor, abbreviation, svgSlug?)
  // svgSlug must exist in assets/brands/<slug>.svg
  static const _banks = <String, (Color, String, String?)>{
    'alrajhi': (Color(0xFF113A7B), 'AR', null),
    'snb': (Color(0xFF006B54), 'SNB', null),
    'riyad': (Color(0xFF004B8D), 'RB', null),
    'stcpay': (Color(0xFF4F008C), 'STC', null),
    'nbe': (Color(0xFF0E7A3D), 'NBE', null),
    'cib_eg': (Color(0xFF1D4F91), 'CIB', null),
    'banque_misr': (Color(0xFF7A1F2B), 'BM', null),
    'qnb_alahli': (Color(0xFF5C1A52), 'QNB', null),
    'fawry': (Color(0xFFFFD200), 'F', 'fawry'),
    'vodafone_cash': (Color(0xFFE60000), 'VF', 'vodafone'),
    'orange_money': (Color(0xFFFF7900), 'OM', 'orange'),
    'etisalat_cash': (Color(0xFF6AB344), 'ET', null),
  };

  // Keyword → short_code (longest / most specific first)
  static const _nameMap = <String>[
    'RAJHI:alrajhi',
    'الراجحي:alrajhi',
    'ALAHLI:snb',
    'الأهلي السعودي:snb',
    'الأهلي:snb',
    'SNB:snb',
    'RIYAD:riyad',
    'الرياض:riyad',
    'STCPAY:stcpay',
    'STC PAY:stcpay',
    'STC:stcpay',
    'NBE:nbe',
    'الأهلي المصري:nbe',
    'NATIONAL BANK:nbe',
    'CIB:cib_eg',
    'BANQUE MISR:banque_misr',
    'بنك مصر:banque_misr',
    'QNB:qnb_alahli',
    'FAWRY:fawry',
    'فوري:fawry',
    'VODAFONE:vodafone_cash',
    'فودافون:vodafone_cash',
    'ORANGE:orange_money',
    'أورنج:orange_money',
    'ETISALAT:etisalat_cash',
    'اتصالات:etisalat_cash',
  ];

  @override
  Widget build(BuildContext context) {
    final shortCode = bankShortCodeFor(accountName);
    final bank = shortCode != null ? _banks[shortCode] : null;

    if (bank != null) {
      final (color, abbr, svgSlug) = bank;
      final radius = size * 0.30;

      if (svgSlug != null) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: SvgPicture.asset(
            'assets/brands/$svgSlug.svg',
            width: size,
            height: size,
            fit: BoxFit.cover,
          ),
        );
      }

      // Colored rounded square + white abbreviation
      final fontSize = size * (abbr.length > 2 ? 0.26 : 0.32);
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(radius),
        ),
        alignment: Alignment.center,
        child: Text(
          abbr,
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w900,
            fontSize: fontSize,
            letterSpacing: -0.5,
          ),
        ),
      );
    }

    // Fallback: generic account-type icon
    final c = Theme.of(context).colorScheme;
    final fallbackColor = c.primary;
    final icon = switch (accountType) {
      AccountType.bank => Icons.account_balance_outlined,
      AccountType.wallet => Icons.account_balance_wallet_outlined,
      AccountType.card => Icons.credit_card_outlined,
      AccountType.cash => Icons.payments_outlined,
    };
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: fallbackColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(size * 0.30),
      ),
      alignment: Alignment.center,
      child: Icon(icon, color: fallbackColor, size: size * 0.52),
    );
  }
}

/// Resolves an account name to its short_code via fuzzy keyword matching.
String? bankShortCodeFor(String name) {
  final upper = name.toUpperCase();
  for (final entry in BankMark._nameMap) {
    final colon = entry.indexOf(':');
    final keyword = entry.substring(0, colon).toUpperCase();
    if (upper.contains(keyword)) return entry.substring(colon + 1);
  }
  return null;
}

/// Derives a display color for an account (used for chips, avatars, etc.).
Color bankColorFor(String accountName) {
  final shortCode = bankShortCodeFor(accountName);
  if (shortCode == null) return const Color(0xFF6B7280);
  final bank = BankMark._banks[shortCode];
  return bank?.$1 ?? const Color(0xFF6B7280);
}

/// Returns the two-letter abbreviation for an account, for compact displays.
String bankAbbrFor(String accountName) {
  final shortCode = bankShortCodeFor(accountName);
  if (shortCode == null) {
    final trimmed = accountName.trim();
    return trimmed.length >= 2
        ? trimmed.substring(0, min(2, trimmed.length))
        : trimmed;
  }
  final bank = BankMark._banks[shortCode];
  return bank?.$2 ?? accountName.substring(0, 2);
}
