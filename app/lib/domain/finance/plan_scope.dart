import '../../core/utils/riyadh_time.dart';
import '../entities/plan_entity.dart';

/// MALI-048n — the plan scope model made explicit.
enum PlanScopeMode {
  /// No account/card selected → counts every expense in the plan's window and
  /// currency. This is the **documented** contract shown to the user in the
  /// plan form ("if you don't choose an account or card, the plan counts all
  /// expenses in the period"), not an accidental empty-means-everything.
  allExpenses,

  /// One or more accounts/cards selected → only their transactions count
  /// (plus any manually-linked transaction).
  selected,
}

extension PlanScopeX on PlanEntity {
  /// The plan's scope, named in one place instead of scattering `isEmpty`
  /// checks. Per the established plan-form contract, an empty account+card
  /// selection is [PlanScopeMode.allExpenses].
  ///
  /// **APPROVED product decision (2026-08-04):** an empty stored scope
  /// permanently means `allExpenses`. There is deliberately NO separate
  /// "unconfigured" state, no `scope_mode` column, and no UI for the
  /// distinction — this preserves the existing approved product contract, it is
  /// not deferred work.
  PlanScopeMode get scopeMode =>
      accountIds.isEmpty && cardLast4s.isEmpty
          ? PlanScopeMode.allExpenses
          : PlanScopeMode.selected;

  /// A blank currency is an invalid configuration: consumption must fail closed
  /// (zero) rather than sum across every currency.
  bool get hasValidCurrency => currency.trim().isNotEmpty;

  /// Genuine half-open upper bound: the start of the day AFTER the plan's last
  /// day, in the business timezone. The stored [endDate] is a legacy inclusive
  /// last-instant (`23:59:59`); this derives a real calendar boundary from it
  /// WITHOUT any epsilon adjustment (MALI-028 boundary rule).
  DateTime get endExclusive =>
      RiyadhTime.startOfDay(endDate).add(const Duration(days: 1));
}
