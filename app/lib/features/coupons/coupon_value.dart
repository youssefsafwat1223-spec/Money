import '../../domain/finance/money.dart';
import '../../domain/finance/money_format.dart';
import '../../l10n/app_localizations.dart';
import 'coupon_models.dart';

/// How an offer's value is put into words.
///
/// ## Prose is the display authority; this is a summary, never a promise
///
/// The offer's own `title_ar` / `description_ar` / `terms_ar` are what the
/// merchant actually committed to, and they are what the user reads. The
/// structured fields exist so the app can rank and compute — and this class
/// turns them into a short chip alongside the prose, never instead of it.
///
/// So the rule throughout is: **if the structured value is not complete enough
/// to state precisely, say nothing.** A chip reading "20% off" on an offer whose
/// terms say something narrower is worse than no chip, because the chip is the
/// part people believe.
class CouponValueLabel {
  const CouponValueLabel._();

  /// The headline value chip, or null when there is nothing certain to say.
  ///
  /// Null for the entire pre-Phase-1 catalog — every offer whose value lives
  /// only in prose — and that is the correct outcome, not a gap to fill.
  static String? headline(CouponOffer offer, AppL10n l10n) {
    switch (offer.benefitType) {
      case 'percent':
        final bps = offer.discountBps;
        if (bps == null || bps <= 0) return null;
        return l10n.couponsValuePercent(_formatBps(bps));
      case 'fixed_amount':
        final minor = offer.fixedAmountMinor;
        final currency = offer.benefitCurrency;
        if (minor == null || minor <= 0 || currency == null) return null;
        return l10n.couponsValueFixed(_money(minor, currency));
      case 'free_shipping':
        return l10n.couponsValueFreeShipping;
      default:
        // 'other' and null both mean "the prose says it". Inventing a generic
        // label like "Discount" would add nothing and imply a computation
        // happened.
        return null;
    }
  }

  /// The qualifier under the headline — a minimum spend, a cap, or both.
  ///
  /// These matter more than the headline for honesty: "20% off" and "20% off
  /// over 200, up to 50" are different offers, and showing only the first is
  /// how a user ends up feeling misled by a number the app chose to display.
  static String? qualifier(CouponOffer offer, AppL10n l10n) {
    final currency = offer.benefitCurrency;
    if (currency == null) return null;

    final parts = <String>[];
    final minSpend = offer.minSpendMinor;
    if (minSpend != null && minSpend > 0) {
      parts.add(l10n.couponsValueMinSpend(_money(minSpend, currency)));
    }
    final cap = offer.maxSavingMinor;
    // A cap only qualifies a percentage. On a fixed amount it is redundant, and
    // 0095's CHECK forbids it anyway.
    if (cap != null && cap > 0 && offer.benefitType == 'percent') {
      parts.add(l10n.couponsValueUpTo(_money(cap, currency)));
    }
    return parts.isEmpty ? null : parts.join(' · ');
  }

  /// How the offer was checked. Always present, because "nobody checked this"
  /// is information the user is entitled to — an unverified offer must not read
  /// like a verified one by omission.
  static String verification(CouponOffer offer, AppL10n l10n) {
    switch (offer.verificationState) {
      case 'admin_verified':
        return l10n.couponsVerifiedByUs;
      case 'provider_verified':
        return l10n.couponsVerifiedByProvider;
      default:
        return l10n.couponsUnverified;
    }
  }

  static bool isVerified(CouponOffer offer) =>
      offer.verificationState == 'admin_verified' ||
      offer.verificationState == 'provider_verified';

  /// `1250` becomes `12.5`, `2000` becomes `20`. Trailing `.0` is dropped so the
  /// common whole-percent case reads naturally.
  static String _formatBps(int bps) {
    if (bps % 100 == 0) return (bps ~/ 100).toString();
    final text = (bps / 100).toStringAsFixed(2);
    return text.endsWith('0') ? text.substring(0, text.length - 1) : text;
  }

  /// Formats through the app's own money contract so a coupon amount is written
  /// exactly like every other amount in the app — same separators, same digits,
  /// same currency placement.
  ///
  /// `Money` throws on a currency it does not know, which is the right failure:
  /// an amount in a currency the app cannot scale is not an amount it can show.
  /// The caller only reaches here after `benefitCurrency` passed the ISO shape
  /// check, so an unknown code means the catalog published something the app
  /// genuinely cannot render, and rendering it wrongly would be worse.
  static String _money(int minor, String currency) {
    try {
      return formatMoney(Money(minor, currency));
    } catch (_) {
      return '';
    }
  }
}
