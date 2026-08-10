import 'package:drift/drift.dart';

import '../../domain/finance/money.dart';

/// MALI-026 (Phase-8 B8-2 §2) — the dual-schema money persistence adapter.
///
/// Every money column is stored as raw SQL through this codec, so the repository
/// / sync / import layers operate purely on [Money] and never know which physical
/// representation the schema uses:
///
///   schema v29:  REAL      ⇄  Money.fromLegacyReal / exact-decimal REAL literal
///   schema v30:  INTEGER `_minor` (+ REAL compatibility shadow)  ⇄  Money(minor)
///
/// This is the SINGLE place that knows the authoritative physical representation.
/// The v30 branch is present and unit-tested (via [read] with `minor:`) so the
/// "v30-capable" read/write path is proven now, even though schema v29 keeps the
/// mode fixed at [MoneyStorageMode.v29Real] and no `_minor` column exists yet.
///
/// `Money.fromLegacyReal` appears ONLY here (the explicit v29 read adapter) and in
/// the v29→v30 migration / legacy recovery — never on a normal write source.
enum MoneyStorageMode {
  /// Schema v29: money lives in REAL columns; REAL is authoritative.
  v29Real,

  /// Schema v30: money lives in INTEGER `_minor` columns; `_minor` is
  /// authoritative and REAL is a compatibility shadow.
  v30Minor,
}

/// The active physical mode for THIS build. Schema is v29, so REAL is
/// authoritative. The v30 activation commit flips this constant (and adds the 20
/// `_minor` columns + their write bindings) — see PHASE_8_B8_2_CUTOVER.md §15.
const MoneyStorageMode kMoneyStorageMode = MoneyStorageMode.v29Real;

/// Shared const codec for the active build mode — the single instance the
/// repository / sync / import layers bind money through.
const MoneyCodec kMoneyCodec = MoneyCodec();

/// Thrown when the physical row is missing a value the current mode requires
/// (should never happen against a consistent schema — fail closed, never guess).
class MoneyStorageException implements Exception {
  const MoneyStorageException(this.message);
  final String message;
  @override
  String toString() => 'MoneyStorageException: $message';
}

class MoneyCodec {
  const MoneyCodec([this.mode = kMoneyStorageMode]);

  final MoneyStorageMode mode;

  // ── READ: physical value → canonical Money ────────────────────────────────

  /// Convert a physical value to [Money]. Pass the value the LIVE schema exposes:
  /// [real] in v29, [minor] in v30. The mode selects which is authoritative; the
  /// conversion is exact for `_minor` and the deterministic legacy quantization
  /// for REAL.
  Money read({double? real, int? minor, required String currency}) {
    switch (mode) {
      case MoneyStorageMode.v29Real:
        if (real == null) {
          throw const MoneyStorageException('v29 read requires a REAL value');
        }
        return Money.fromLegacyReal(real, currency);
      case MoneyStorageMode.v30Minor:
        if (minor == null) {
          throw const MoneyStorageException('v30 read requires a minor value');
        }
        return Money(minor, currency);
    }
  }

  /// Nullable-money variant (absent money column → `null` Money).
  Money? readNullable({double? real, int? minor, required String currency}) {
    switch (mode) {
      case MoneyStorageMode.v29Real:
        return real == null ? null : Money.fromLegacyReal(real, currency);
      case MoneyStorageMode.v30Minor:
        return minor == null ? null : Money(minor, currency);
    }
  }

  /// Row-level convenience: read [column] money from a Drift [QueryRow] in the
  /// authoritative representation for the current mode (v29: REAL `column`;
  /// v30: INTEGER `${column}_minor`). The conversion itself is delegated to
  /// [read], so the exactness contract is covered by a single set of tests.
  Money readColumn(QueryRow row, String column, String currency) =>
      mode == MoneyStorageMode.v29Real
          ? read(real: row.read<double>(column), currency: currency)
          : read(minor: row.read<int>('${column}_minor'), currency: currency);

  Money? readColumnNullable(QueryRow row, String column, String currency) =>
      mode == MoneyStorageMode.v29Real
          ? readNullable(real: row.readNullable<double>(column), currency: currency)
          : readNullable(
              minor: row.readNullable<int>('${column}_minor'), currency: currency);

  // ── WRITE: canonical Money → physical bind ────────────────────────────────

  /// The REAL storage encoding of an exact [Money] — v29 authoritative column and
  /// v30 compatibility shadow. Derived from the EXACT decimal string, so it is the
  /// nearest REAL to the true value (exact for |minorUnits| ≤ 2^53; beyond that
  /// REAL is inherently lossy — the v29 storage limitation the §13 test documents).
  /// The [Money] is the exact SOURCE; this method only performs the physical
  /// (lossy-in-the-extreme) storage encoding the schema demands today.
  double toReal(Money m) => double.parse(m.toDecimalString());

  /// The exact integer minor units — the v30 authoritative column value.
  int toMinor(Money m) => m.minorUnits;

  /// Bound `?` variable for the REAL column (v29). Callers that use bound
  /// parameters (`Variable.withReal`) pass [realVar]/[realVarOrNull].
  Variable<double> realVar(Money m) => Variable.withReal(toReal(m));
  Variable<double> realVarOrNull(Money? m) =>
      m == null ? const Variable<double>(null) : realVar(m);

  /// SQL numeric literal for the interpolation writers (the transactions/goals
  /// repositories build SQL text). Emits the EXACT decimal (`19.99`, `-0.50`,
  /// `1234`) — a valid REAL literal, strictly better than `double.toString()`
  /// (which can leak `19.989999999`). NULL for absent money.
  String sqlRealLiteral(Money m) => m.toDecimalString();
  String sqlNullableRealLiteral(Money? m) =>
      m == null ? 'NULL' : m.toDecimalString();
}
