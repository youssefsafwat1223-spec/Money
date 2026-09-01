import 'package:drift/drift.dart';

import '../../core/utils/id_generator.dart';
import '../../data/db/app_database.dart';
import 'savings_math.dart';

/// One recorded saving.
class SavingsEntry {
  const SavingsEntry({
    required this.id,
    required this.couponId,
    required this.amountMinor,
    required this.currency,
    required this.evidence,
    required this.occurredAt,
    this.merchantId,
    this.clickId,
    this.reversed = false,
  });

  final String id;
  final String couponId;
  final String? merchantId;
  final String? clickId;
  final int amountMinor;
  final String currency;
  final SavingsEvidence evidence;
  final DateTime occurredAt;
  final bool reversed;
}

/// A per-currency, per-evidence total.
///
/// Deliberately NOT a single number. Two things are being kept apart:
///
///  * **Currencies**, because there is no FX design and adding SAR to EGP would
///    produce a figure in no currency at all.
///  * **Evidence**, because "you saved 400" built from a user's own guesses and
///    a provider's confirmed numbers is a claim the app cannot stand behind.
///    The moment someone checks one entry and finds it was an estimate, every
///    other number inherits the doubt.
class SavingsTotals {
  const SavingsTotals(this.byCurrencyAndEvidence);

  /// `{'SAR': {userConfirmed: 12000, conversionVerified: 3000}}`
  final Map<String, Map<SavingsEvidence, int>> byCurrencyAndEvidence;

  /// The total for one currency across all evidence kinds.
  ///
  /// Safe ONLY because the UI that calls it also shows the breakdown — a single
  /// number with no provenance is exactly what this class exists to prevent, so
  /// callers must render both.
  int totalFor(String currency) =>
      (byCurrencyAndEvidence[currency] ?? const {})
          .values
          .fold<int>(0, (a, b) => a + b);

  /// Only what a provider actually confirmed. The number the app can defend
  /// without qualification.
  int verifiedFor(String currency) =>
      byCurrencyAndEvidence[currency]?[SavingsEvidence.conversionVerified] ?? 0;

  bool get isEmpty => byCurrencyAndEvidence.isEmpty;
}

/// The LOCAL savings ledger.
///
/// Never uploaded. A server-side savings total would be a spending profile, and
/// there is no product reason for one to exist off the device — the user is the
/// only party who needs to know what they saved.
class SavingsRepository {
  const SavingsRepository(this._db);

  final AppDatabase _db;

  /// Records a saving. Refuses anything that is not an actual amount.
  ///
  /// Returns null when [outcome] abstained, so a caller cannot accidentally
  /// write "0" for an offer whose value we could not compute — zero reads as
  /// "you saved nothing", which is a different and false statement.
  Future<String?> record(
    SavingsOutcome outcome, {
    required String couponId,
    String? merchantId,
    String? clickId,
    DateTime? occurredAt,
  }) async {
    if (!outcome.hasAmount) return null;
    final id = IdGenerator.uuidV4();
    final now = DateTime.now().toUtc();
    await _db.customInsert(
      '''
        INSERT INTO local_offer_savings(
          id, coupon_id, merchant_id, click_id, evidence_kind,
          amount_minor, currency, state, occurred_at, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, 'active', ?, ?);
      ''',
      variables: [
        Variable.withString(id),
        Variable.withString(couponId),
        if (merchantId == null) const Variable<String>(null) else Variable.withString(merchantId),
        if (clickId == null) const Variable<String>(null) else Variable.withString(clickId),
        Variable.withString(outcome.evidence!.name),
        Variable.withInt(outcome.amountMinor!),
        Variable.withString(outcome.currency!),
        Variable.withString((occurredAt ?? now).toUtc().toIso8601String()),
        Variable.withString(now.toIso8601String()),
      ],
    );
    return id;
  }

  /// Reverses an entry after a provider clawback.
  ///
  /// The row is marked `reversed`, never deleted. A user who saw "you saved 50"
  /// and later sees it gone deserves the record of it having been reversed —
  /// silently removing it looks like the app losing data, which is worse for
  /// trust than the reversal itself.
  Future<void> reverseForClick(String clickId) async {
    await _db.customUpdate(
      "UPDATE local_offer_savings SET state = 'reversed' WHERE click_id = ?;",
      variables: [Variable.withString(clickId)],
    );
  }

  /// Active entries only, newest first.
  Future<List<SavingsEntry>> history({int limit = 100}) async {
    final rows = await _db.customSelect(
      "SELECT * FROM local_offer_savings WHERE state = 'active' "
      'ORDER BY occurred_at DESC LIMIT ?;',
      variables: [Variable.withInt(limit)],
    ).get();
    return rows.map(_fromRow).toList();
  }

  /// Totals, split by currency AND by evidence. There is deliberately no method
  /// that returns one number for everything.
  Future<SavingsTotals> totals() async {
    final rows = await _db.customSelect(
      '''
        SELECT currency, evidence_kind, SUM(amount_minor) AS total
          FROM local_offer_savings
         WHERE state = 'active'
         GROUP BY currency, evidence_kind;
      ''',
    ).get();

    final out = <String, Map<SavingsEvidence, int>>{};
    for (final row in rows) {
      final currency = row.read<String>('currency');
      final evidence = _evidenceFrom(row.read<String>('evidence_kind'));
      if (evidence == null) continue;
      (out[currency] ??= <SavingsEvidence, int>{})[evidence] =
          row.read<int>('total');
    }
    return SavingsTotals(Map.unmodifiable(out));
  }

  static SavingsEvidence? _evidenceFrom(String raw) {
    for (final e in SavingsEvidence.values) {
      if (e.name == raw) return e;
    }
    // An unknown kind — written by a newer build, or corrupted — is EXCLUDED
    // from every total rather than bucketed into one. A figure is only
    // defensible if we know what each part of it means.
    return null;
  }

  static SavingsEntry _fromRow(QueryRow r) => SavingsEntry(
        id: r.read<String>('id'),
        couponId: r.read<String>('coupon_id'),
        merchantId: r.readNullable<String>('merchant_id'),
        clickId: r.readNullable<String>('click_id'),
        amountMinor: r.read<int>('amount_minor'),
        currency: r.read<String>('currency'),
        evidence: _evidenceFrom(r.read<String>('evidence_kind')) ??
            SavingsEvidence.userConfirmed,
        occurredAt: DateTime.parse(r.read<String>('occurred_at')),
        reversed: r.read<String>('state') != 'active',
      );
}
