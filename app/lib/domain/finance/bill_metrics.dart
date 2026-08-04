// MALI-064n — the ONE bill / subscription metric + payment-attribution
// contract. Every surface (bill details, subscription list, transactions
// screen, reports) derives "monthly total" and "paid total" from HERE, so the
// same label never means two different numbers and one real payment is counted
// exactly once.
import '../entities/bill_entity.dart';

// ── Recurrence normalization ────────────────────────────────────────────────

/// The **annual-equivalent** cost of a recurring bill, normalized from its
/// billing frequency: weekly ×52, monthly ×12, yearly ×1, custom = amount ×
/// (365 / intervalDays). One normalization, used everywhere.
double annualEquivalent(BillEntity bill) {
  switch (bill.frequency) {
    case BillFrequency.weekly:
      return bill.amount * 52;
    case BillFrequency.monthly:
      return bill.amount * 12;
    case BillFrequency.yearly:
      return bill.amount;
    case BillFrequency.custom:
      final days = bill.customIntervalDays ?? 30;
      return days <= 0 ? bill.amount * 12 : bill.amount * (365 / days);
  }
}

/// The **monthly-equivalent** recurring obligation of a bill — exactly
/// [annualEquivalent] / 12, so a monthly total and its ×12 annual total can
/// never disagree (they previously used two different weekly/custom divisors).
double monthlyEquivalent(BillEntity bill) => annualEquivalent(bill) / 12;

/// The projected **monthly recurring obligation** across [bills] — active
/// subscriptions only. Summed within a single currency scope; callers must
/// scope by account/currency, never mix currencies under one label.
double subscriptionMonthlyTotal(Iterable<BillEntity> bills) => bills
    .where((b) =>
        b.type == BillType.subscription && b.status == BillStatus.active)
    .fold<double>(0, (sum, b) => sum + monthlyEquivalent(b));

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
  const BillPaidSummary({required this.recorded, required this.legacyManual});

  /// Σ of recorded `bill_payments` amounts (each real payment once).
  final double recorded;

  /// `max(0, manualPaidAmount − recorded)` — a legacy manual total kept only
  /// for the part not already represented by recorded payments.
  final double legacyManual;

  double get total => recorded + legacyManual;
}

BillPaidSummary billPaidTotal({
  required Iterable<BillPaymentEntity> payments,
  required double manualPaidAmount,
}) {
  final recorded = payments.fold<double>(0, (sum, p) => sum + p.amount);
  final legacyManual =
      (manualPaidAmount - recorded).clamp(0.0, double.infinity).toDouble();
  return BillPaidSummary(recorded: recorded, legacyManual: legacyManual);
}

/// Transaction ids already represented by a recorded payment (via
/// `transactionId`). Used to keep an already-linked transaction out of the
/// "suggested to link" list so it is never offered twice or double-counted.
Set<String> linkedTransactionIds(Iterable<BillPaymentEntity> payments) => {
      for (final p in payments)
        if (p.transactionId != null) p.transactionId!,
    };
