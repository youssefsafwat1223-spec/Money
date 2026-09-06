import 'package:drift/drift.dart';

import '../db/app_database.dart';

/// What a user did to a captured transaction, for Proof correctness measurement.
enum ProofCorrectionEvent {
  /// Accepted as parsed — status flipped, no Proof-relevant field changed.
  confirmed,

  /// A Proof-relevant field was changed. THE correctness-failure signal.
  correctedFinancial,

  /// Rejected or deleted outright.
  rejectedOrDeleted,

  /// Edited, but only in ways Proof does not corroborate (category, merchant
  /// name, note, date). Recorded so the population is visible, and deliberately
  /// NOT a correctness failure.
  nonFinancialEdit,
}

/// Who caused an edit.
///
/// The raw-SQL immunity argument covers sync, import and migration — but NOT
/// `AccountCurrencyRepairService`, which runs at EVERY BOOT and deliberately
/// routes through the repository to get outbox enqueueing. It backfills
/// `account_id` on orphaned rows with no user involved, and would otherwise
/// append a `corrected_financial` per row from the first shipped boot. Since the
/// log is append-only and carries nothing distinguishing repair from user, that
/// poison would not be separable afterwards.
///
/// So origin is DECLARED, never inferred. A system writer must say so.
enum ProofEditOrigin {
  /// A person acted on this transaction.
  user,

  /// A background repair, backfill or reconciliation. Never a correctness
  /// signal: the parse was not wrong, the app was fixing its own bookkeeping.
  systemRepair,
}

/// The Proof-relevant field classes. Names only ever appear as CLASS LABELS in
/// the log — never the values that changed.
enum ProofField { amount, currency, direction, account }

/// Append-only provenance for "was this parse later confirmed or corrected".
///
/// ## Why this exists rather than reading `updated_at`
///
/// `confirm()` bumps `updated_at` exactly as an edit does, so the timestamp
/// cannot distinguish "the user agreed" from "the user fixed it" — the two
/// outcomes whose difference is the entire correctness question. Worse,
/// `updated_at` is also moved by writers that are not the user at all.
///
/// ## Why writing at the repository layer is the load-bearing choice
///
/// Every non-user writer mutates `transactions` with RAW SQL and never calls
/// these methods: sync pull-apply and tombstones
/// (`ledger_sync_service.dart`), the data-import soft-hide
/// (`drift_financial_importer.dart`), and the migration timestamp repair
/// (`app_database.dart`). So a sync touch physically cannot emit a correction
/// event. That immunity is structural, not a filter someone has to remember.
///
/// ## What is stored
///
/// Transaction id, event type, which FIELD CLASSES changed, and a timestamp.
/// No amounts, no currencies, no merchant, no message text — the question is
/// "did the amount change", never "what was it".
class ProofCorrectionLog {
  ProofCorrectionLog(this._db);

  final AppDatabase _db;

  /// Which Proof-relevant classes differ between the stored row and the edit.
  ///
  /// `account` is included even though `ProofChecker` does not corroborate an
  /// account today. That is deliberate and conservative: counting an account
  /// change as a correction can only make the release gate STRICTER, never
  /// looser, and a metric that errs toward "we got it wrong" is the safe
  /// direction for a financial safety gate.
  static Set<ProofField> financialDelta({
    required int? oldAmountMinor,
    required int? newAmountMinor,
    required String? oldCurrency,
    required String? newCurrency,
    required String? oldType,
    required String? newType,
    required String? oldAccountId,
    required String? newAccountId,
  }) {
    final changed = <ProofField>{};
    if (oldAmountMinor != null &&
        newAmountMinor != null &&
        oldAmountMinor != newAmountMinor) {
      changed.add(ProofField.amount);
    }
    bool differs(String? a, String? b) =>
        (a ?? '').trim().toUpperCase() != (b ?? '').trim().toUpperCase();
    if (differs(oldCurrency, newCurrency)) changed.add(ProofField.currency);
    if (differs(oldType, newType)) changed.add(ProofField.direction);
    if ((oldAccountId ?? '') != (newAccountId ?? '')) {
      changed.add(ProofField.account);
    }
    return changed;
  }

  /// Record one event. NEVER throws: provenance is diagnostic, and a diagnostic
  /// write must not be able to fail a user's edit.
  Future<void> record({
    required String transactionId,
    required ProofCorrectionEvent event,
    Set<ProofField> changedFields = const {},
  }) async {
    try {
      await _db.customInsert(
        'INSERT INTO proof_correction_events '
        '(id, transaction_id, event_type, changed_fields, occurred_at) '
        'VALUES (?,?,?,?,?)',
        variables: <Variable<Object>>[
          Variable<String>(
              '$transactionId:${DateTime.now().toUtc().microsecondsSinceEpoch}'),
          Variable<String>(transactionId),
          Variable<String>(_wire(event)),
          Variable<String>(
              (changedFields.map((f) => f.name).toList()..sort()).join(',')),
          Variable<String>(DateTime.now().toUtc().toIso8601String()),
        ],
      );
    } catch (_) {
      // Never load-bearing.
    }
  }

  /// Convenience for an edit: emits the right event based on the delta, so no
  /// call site has to decide what counts as financial.
  Future<void> recordEdit({
    required String transactionId,
    required Set<ProofField> changedFields,
    ProofEditOrigin origin = ProofEditOrigin.user,
  }) async {
    // A system repair is not evidence about the parse. Recording nothing is
    // correct here: the alternative — a distinguishable "repair" event — would
    // still have to be excluded by every reader, and one reader forgetting is a
    // silently inflated correction count.
    if (origin == ProofEditOrigin.systemRepair) return;
    return record(
      transactionId: transactionId,
      event: changedFields.isEmpty
          ? ProofCorrectionEvent.nonFinancialEdit
          : ProofCorrectionEvent.correctedFinancial,
      changedFields: changedFields,
    );
  }

  static String _wire(ProofCorrectionEvent e) => switch (e) {
        ProofCorrectionEvent.confirmed => 'confirmed',
        ProofCorrectionEvent.correctedFinancial => 'corrected_financial',
        ProofCorrectionEvent.rejectedOrDeleted => 'rejected_or_deleted',
        ProofCorrectionEvent.nonFinancialEdit => 'non_financial_edit',
      };
}
