import '../../domain/finance/currency_scale.dart';
import '../../domain/finance/decimal_minor.dart';
import 'app_database.dart';

/// MALI-026 (Phase-8 B8-3 §10/§13, corrections 2/3) — the FULL canonical planning
/// contract validator, shared by the cutover executor's postflight and the
/// coordinator's boot recompute. "Canonical" means EVERY invariant holds, not
/// merely that a minor column exists.
///
/// Covers EVERY persisted planning row (including soft-deleted / archived — §4:
/// they can reappear via restore/sync, so they carry financial authority and must
/// be canonical too). Returns privacy-safe violation labels (field/id, never an
/// amount); an empty list means the dataset is canonical.
Future<List<String>> planningCanonicalViolations(AppDatabase db) async {
  final v = <String>[];

  // Row-currency must be present AND in the supported registry (SQL cannot check
  // the Dart registry, so the currency is resolved here and validated in Dart).
  void checkField({
    required String table,
    required String id,
    required String? currency,
    required double? real,
    required int? minor,
    required String field,
  }) {
    if (currency == null || !isSupportedCurrency(currency)) {
      v.add('$table.$id: currency "${currency ?? '<null>'}" not canonical/supported');
      return; // can't validate minor without a valid scale
    }
    if (real == null) {
      if (minor != null) v.add('$table.$id.$field: minor set for NULL REAL');
      return; // legitimate NULL <-> NULL
    }
    if (minor == null) {
      v.add('$table.$id.$field: required minor is NULL');
      return;
    }
    if (minor != legacyRealToMinor(real, currencyScale(currency))) {
      v.add('$table.$id.$field: minor != exact(real)');
    }
  }

  // ── budgets ────────────────────────────────────────────────────────────────
  for (final r in await db
      .customSelect('SELECT id, currency, amount, amount_minor, '
          'last_notified_spent_amount, last_notified_spent_amount_minor '
          'FROM budgets;')
      .get()) {
    final id = r.read<String>('id');
    final cur = r.readNullable<String>('currency');
    checkField(
        table: 'budgets',
        id: id,
        currency: cur,
        real: r.readNullable<double>('amount'),
        minor: r.readNullable<int>('amount_minor'),
        field: 'amount');
    checkField(
        table: 'budgets',
        id: id,
        currency: cur,
        real: r.readNullable<double>('last_notified_spent_amount'),
        minor: r.readNullable<int>('last_notified_spent_amount_minor'),
        field: 'last_notified_spent_amount');
  }

  // ── goals ──────────────────────────────────────────────────────────────────
  for (final r in await db
      .customSelect('SELECT id, currency, target_amount, target_amount_minor, '
          'saved_amount, saved_amount_minor, last_notified_saved_amount, '
          'last_notified_saved_amount_minor, auto_save_amount, '
          'auto_save_amount_minor FROM goals;')
      .get()) {
    final id = r.read<String>('id');
    final cur = r.readNullable<String>('currency');
    for (final f in const [
      ('target_amount', 'target_amount_minor'),
      ('saved_amount', 'saved_amount_minor'),
      ('last_notified_saved_amount', 'last_notified_saved_amount_minor'),
      ('auto_save_amount', 'auto_save_amount_minor'), // legitimately nullable
    ]) {
      checkField(
          table: 'goals',
          id: id,
          currency: cur,
          real: r.readNullable<double>(f.$1),
          minor: r.readNullable<int>(f.$2),
          field: f.$1);
    }
  }

  // ── goal_contributions (currency inherited from the parent goal) ────────────
  for (final r in await db
      .customSelect('SELECT gc.id AS id, gc.amount AS amount, '
          'gc.amount_minor AS minor, gc.goal_id AS goal_id, '
          'g.id AS parent_id, g.currency AS parent_currency '
          'FROM goal_contributions gc '
          'LEFT JOIN goals g ON g.id = gc.goal_id;')
      .get()) {
    final id = r.read<String>('id');
    if (r.readNullable<String>('parent_id') == null) {
      v.add('goal_contributions.$id: orphan (parent goal ${r.read<String>('goal_id')} missing)');
      continue;
    }
    checkField(
        table: 'goal_contributions',
        id: id,
        currency: r.readNullable<String>('parent_currency'),
        real: r.readNullable<double>('amount'),
        minor: r.readNullable<int>('minor'),
        field: 'amount');
  }

  return v;
}
