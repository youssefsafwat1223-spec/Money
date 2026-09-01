import '../../domain/finance/currency_scale.dart';
import 'coupon_models.dart';

/// How much we actually know about a saving.
///
/// These are NEVER summed into one figure without saying which is which. "You
/// saved 400 riyals" built from a user's own guesses and a provider's confirmed
/// numbers is a claim the app cannot stand behind, and the moment a user checks
/// one entry and finds it was an estimate, every other number loses its
/// credibility too.
enum SavingsEvidence {
  /// The user told us they used the offer. We applied the offer's own terms to
  /// a basket size they supplied. Honest, and entirely their arithmetic.
  userConfirmed,

  /// A provider reported a sale against our click, and we applied the OFFER's
  /// discount to the order amount they reported. The sale is real; the discount
  /// is our calculation.
  conversionEstimated,

  /// A provider reported the actual discount amount. The only kind we did not
  /// compute ourselves.
  conversionVerified,
}

/// Why no figure could be produced. Abstention is a first-class result: in a
/// finance app a wrong saving is worse than no saving, because the user has no
/// way to check it and every other number inherits the doubt.
enum SavingsAbstention {
  /// The offer's value is prose only — the entire pre-Phase-1 catalog.
  noStructuredBenefit,

  /// `free_shipping` or `other`. Real value, no computable amount, and inventing
  /// a delivery-fee figure would be pure fiction.
  benefitHasNoAmount,

  /// The basket is below the offer's minimum spend, so the offer does not apply.
  belowMinimumSpend,

  /// The basket and the offer are in different currencies. There is no FX design
  /// yet, and converting at a rate we picked would put an invented number in a
  /// user's savings total.
  currencyMismatch,

  /// A currency the money layer cannot scale. Better to show nothing than to
  /// guess the number of decimal places.
  unsupportedCurrency,

  /// A basket amount that cannot produce a sensible saving.
  invalidBasket,
}

class SavingsOutcome {
  const SavingsOutcome._({this.amountMinor, this.currency, this.evidence, this.abstention});

  const SavingsOutcome.saved({
    required int amountMinor,
    required String currency,
    required SavingsEvidence evidence,
  }) : this._(amountMinor: amountMinor, currency: currency, evidence: evidence);

  const SavingsOutcome.abstained(SavingsAbstention reason)
      : this._(abstention: reason);

  final int? amountMinor;
  final String? currency;
  final SavingsEvidence? evidence;
  final SavingsAbstention? abstention;

  bool get hasAmount => amountMinor != null;
}

/// Computes what an offer actually saved, in exact minor units.
///
/// ## The rules that are not negotiable
///
/// * **Commission is never savings.** What a network pays us is our revenue in
///   our currency under our contract. It appears nowhere in this file, and the
///   status endpoint does not even return it to the device.
/// * **An approved conversion is not a verified saving.** "A sale happened"
///   and "the user was discounted this much" are different facts. A conversion
///   without an explicit provider discount yields `conversionEstimated` at best.
/// * **Potential is never actual.** [potentialSaving] exists for the "you could
///   save" chip on a card. It returns the same type but its result must never be
///   written to the ledger, and the ledger has no writer that accepts it.
/// * **Currencies never mix.** No FX. A basket in EGP against an offer in SAR
///   abstains rather than converting at a rate we chose.
class SavingsMath {
  const SavingsMath._();

  /// What this offer WOULD save on a basket of [basketMinor].
  ///
  /// For display only — a "save up to X" chip. Writing this to the ledger would
  /// turn an advertisement into a record of something that happened.
  static SavingsOutcome potentialSaving(
    CouponOffer offer, {
    required int basketMinor,
    required String basketCurrency,
  }) =>
      _compute(offer, basketMinor: basketMinor, basketCurrency: basketCurrency);

  /// What the user says they saved, from a basket they supplied.
  static SavingsOutcome fromUserConfirmation(
    CouponOffer offer, {
    required int basketMinor,
    required String basketCurrency,
  }) {
    final out = _compute(offer, basketMinor: basketMinor, basketCurrency: basketCurrency);
    if (!out.hasAmount) return out;
    return SavingsOutcome.saved(
      amountMinor: out.amountMinor!,
      currency: out.currency!,
      evidence: SavingsEvidence.userConfirmed,
    );
  }

  /// What a provider-reported conversion means for the user.
  ///
  /// [providerDiscountMinor] is the ONLY input that produces
  /// [SavingsEvidence.conversionVerified]. When a provider reports an order
  /// value but no discount, we fall back to applying the offer's own terms —
  /// which is an ESTIMATE, and says so.
  static SavingsOutcome fromConversion(
    CouponOffer offer, {
    required String status,
    int? orderAmountMinor,
    String? orderCurrency,
    int? providerDiscountMinor,
    String? providerDiscountCurrency,
  }) {
    // Only an approved conversion is money the user actually spent. A pending
    // one may still be clawed back, and recording it would mean writing a
    // saving we expect to have to reverse.
    if (status != 'approved') {
      return const SavingsOutcome.abstained(SavingsAbstention.invalidBasket);
    }

    if (providerDiscountMinor != null && providerDiscountMinor > 0) {
      final currency = providerDiscountCurrency;
      if (currency == null || !_supported(currency)) {
        return const SavingsOutcome.abstained(SavingsAbstention.unsupportedCurrency);
      }
      return SavingsOutcome.saved(
        amountMinor: providerDiscountMinor,
        currency: currency,
        evidence: SavingsEvidence.conversionVerified,
      );
    }

    if (orderAmountMinor == null || orderCurrency == null) {
      // A sale happened and we know nothing about its size. There is no honest
      // number here — not zero, which would read as "you saved nothing".
      return const SavingsOutcome.abstained(SavingsAbstention.invalidBasket);
    }

    final out = _compute(offer,
        basketMinor: orderAmountMinor, basketCurrency: orderCurrency);
    if (!out.hasAmount) return out;
    return SavingsOutcome.saved(
      amountMinor: out.amountMinor!,
      currency: out.currency!,
      evidence: SavingsEvidence.conversionEstimated,
    );
  }

  static SavingsOutcome _compute(
    CouponOffer offer, {
    required int basketMinor,
    required String basketCurrency,
  }) {
    if (basketMinor <= 0) {
      return const SavingsOutcome.abstained(SavingsAbstention.invalidBasket);
    }
    if (!offer.hasComputableBenefit) {
      return SavingsOutcome.abstained(
        offer.benefitType == null
            ? SavingsAbstention.noStructuredBenefit
            : SavingsAbstention.benefitHasNoAmount,
      );
    }

    final offerCurrency = offer.benefitCurrency!;
    if (!_supported(offerCurrency) || !_supported(basketCurrency)) {
      return const SavingsOutcome.abstained(SavingsAbstention.unsupportedCurrency);
    }
    if (offerCurrency != basketCurrency.toUpperCase()) {
      // No FX. Converting at a rate we picked would put an invented number in
      // someone's savings total, and the rate would be wrong by the time they
      // looked at it anyway.
      return const SavingsOutcome.abstained(SavingsAbstention.currencyMismatch);
    }

    final minSpend = offer.minSpendMinor;
    if (minSpend != null && basketMinor < minSpend) {
      return const SavingsOutcome.abstained(SavingsAbstention.belowMinimumSpend);
    }

    int amount;
    if (offer.benefitType == 'percent') {
      // Integer arithmetic throughout. A double would make 12.5% of an odd
      // number land a fraction of a minor unit off, and a savings total that
      // does not reconcile with its own entries is a total nobody trusts.
      //
      // Truncating rather than rounding is deliberate: it can only ever
      // UNDERSTATE what the user saved, and understating is the safe direction
      // for a number we are asserting on their behalf.
      amount = (basketMinor * offer.discountBps!) ~/ 10000;
    } else {
      amount = offer.fixedAmountMinor!;
      // A fixed discount cannot exceed the basket. "You saved 50" on a 30-riyal
      // purchase is arithmetically impossible and reads as a bug.
      if (amount > basketMinor) amount = basketMinor;
    }

    final cap = offer.maxSavingMinor;
    if (cap != null && amount > cap) amount = cap;

    if (amount <= 0) {
      // A discount that rounds away to nothing is not a saving.
      return const SavingsOutcome.abstained(SavingsAbstention.invalidBasket);
    }

    return SavingsOutcome.saved(
      amountMinor: amount,
      currency: offerCurrency,
      evidence: SavingsEvidence.userConfirmed,
    );
  }

  /// `kCurrencyScale` is the app's one registry of how many minor units a
  /// currency has. A code it does not know cannot be formatted correctly, and
  /// guessing two decimal places is how a JPY figure ends up a hundred times
  /// wrong.
  static bool _supported(String currency) =>
      kCurrencyScale.containsKey(currency.trim().toUpperCase());
}
