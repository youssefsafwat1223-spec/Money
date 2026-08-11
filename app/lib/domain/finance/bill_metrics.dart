// MALI-064n — the ONE bill / subscription metric + payment-attribution
// contract. Every surface (bill details, subscription list, transactions
// screen, reports) derives "monthly total" and "paid total" from HERE, so the
// same label never means two different numbers and one real payment is counted
// exactly once.
import '../entities/bill_entity.dart';
import 'money.dart';

// ── Recurrence normalization ────────────────────────────────────────────────

/// The **annual-equivalent** cost of a recurring bill, normalized from its
/// billing frequency: weekly ×52, monthly ×12, yearly ×1, custom = amount ×
/// (365 / intervalDays). One normalization, used everywhere.
Money annualEquivalentMoney(BillEntity bill) {
  switch (bill.frequency) {
    case BillFrequency.weekly:
      return bill.amountMoney * 52;
    case BillFrequency.monthly:
      return bill.amountMoney * 12;
    case BillFrequency.yearly:
      return bill.amountMoney;
    case BillFrequency.custom:
      final days = bill.customIntervalDays ?? 30;
      return days <= 0
          ? bill.amountMoney * 12
          : bill.amountMoney.applyRate(
              rateNumerator: BigInt.from(365),
              rateDenominator: BigInt.from(days),
            );
  }
}

double annualEquivalent(BillEntity bill) =>
    annualEquivalentMoney(bill).toDouble();

/// The **monthly-equivalent** recurring obligation of a bill. The annual value
/// is divided by 12 as an exact ratio and quantized once at the bill currency's
/// minor-unit boundary.
Money monthlyEquivalentMoney(BillEntity bill) =>
    annualEquivalentMoney(bill).applyRate(
      rateNumerator: BigInt.one,
      rateDenominator: BigInt.from(12),
    );

double monthlyEquivalent(BillEntity bill) =>
    monthlyEquivalentMoney(bill).toDouble();

/// The projected **monthly recurring obligation** across [bills] — active
/// subscriptions only. The existing UI model may mix currencies under one
/// presentation label, so each bill is calculated exactly as Money before the
/// final legacy display fold.
double subscriptionMonthlyTotal(Iterable<BillEntity> bills) {
  final active = bills
      .where((b) =>
          b.type == BillType.subscription && b.status == BillStatus.active)
      .toList(growable: false);
  if (active.isEmpty) return 0;
  return active.fold<double>(
    0,
    (sum, bill) => sum + monthlyEquivalentMoney(bill).toDouble(),
  );
}

// ── Payment attribution ─────────────────────────────────────────────────────

/// The authoritative paid total for a bill.
///
/// `bill_payments` is the settled-payment ledger: each row is exactly one
/// payment (optionally carrying `transactionId` for its bank transaction), so a
/// payment counts once no matter how many representations exist. The legacy
/// manual paid-amount contributes only the residual beyond the recorded rows.
/// Fuzzy merchant-name matched transactions are NEVER counted here — they are
/// only suggestions to link (see [linkedTransactionIds]).
class BillPaidSummary {
  const BillPaidSummary({
    required this.recordedMoney,
    required this.legacyManualMoney,
  });

  /// Σ of recorded `bill_payments` amounts (each real payment once).
  final Money recordedMoney;

  /// `max(0, manualPaidAmount − recorded)` — a legacy manual total kept only
  /// for the part not already represented by recorded payments.
  final Money legacyManualMoney;

  Money get totalMoney => recordedMoney + legacyManualMoney;
  double get recorded => recordedMoney.toDouble();
  double get legacyManual => legacyManualMoney.toDouble();
  double get total => totalMoney.toDouble();
}

BillPaidSummary billPaidTotal({
  required Iterable<BillPaymentEntity> payments,
  required Money manualPaidMoney,
}) {
  final recordedMoney = Money.sum(
    payments.map((payment) => payment.amountMoney),
    manualPaidMoney.currency,
  );
  final residual = manualPaidMoney - recordedMoney;
  final legacyManualMoney =
      residual.isNegative ? Money.zero(manualPaidMoney.currency) : residual;
  return BillPaidSummary(
    recordedMoney: recordedMoney,
    legacyManualMoney: legacyManualMoney,
  );
}

/// Transaction ids already represented by a recorded payment (via
/// `transactionId`). Used to keep an already-linked transaction out of the
/// "suggested to link" list so it is never offered twice or double-counted.
Set<String> linkedTransactionIds(Iterable<BillPaymentEntity> payments) => {
      for (final p in payments)
        if (p.transactionId != null) p.transactionId!,
    };
