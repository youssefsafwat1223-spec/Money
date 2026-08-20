import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../domain/finance/currency_scale.dart';
import 'app_database.dart';

/// MALI-026 (Phase-8 B8-2.6) — pre-v30 PLANNING-CURRENCY REPAIR foundation.
///
/// budgets / goals / goal_contributions store money with NO per-row currency; a
/// pre-v30 row's ORIGINAL currency is IRRECOVERABLE from the database (base
/// currency was freely mutable and nothing recorded it). So v30 must NOT silently
/// stamp the current base currency onto historical rows. This module records a
/// DURABLE, user-confirmed repair decision (while schema is still v29) that the
/// future v30 migration consumes deterministically.
///
/// Storage is the app's flutter_secure_storage KV (no new schema), namespaced +
/// bound to the local install (and the signed-in user, if any) so it can never apply to another
/// dataset. It carries a SEMANTIC FINGERPRINT of the planning objects' IDENTITY
/// (goals: id+created_at; budgets: id — NOT their monetary/mutable-business
/// values), so a decision is rejected as stale when a budget/goal is added,
/// deleted, or (for goals) recreated under the same id; a restore that brings a
/// DIFFERENT dataset is handled by the restore payload's own scoped repair —
/// while a harmless amount edit or goal contribution (a row's currency is
/// orthogonal to its amount) does NOT invalidate it. Contributions
/// derive their currency from the parent goal — there is NO contribution currency.
///
/// This is the FOUNDATION (model + service + fingerprint + consume API + tests).
/// No schema change, no `_minor`, no migration activation — v30 stays blocked.

/// The durable key/value seam the repair decision is persisted through. The app
/// wires [SecureRepairKeyValueStore] (flutter_secure_storage — the app's existing
/// crash-safe, install-scoped store, same mechanism as InstallId / app-lock);
/// tests use an in-memory implementation. No new database schema is introduced.
abstract class RepairKeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// flutter_secure_storage-backed [RepairKeyValueStore] (the production wiring).
class SecureRepairKeyValueStore implements RepairKeyValueStore {
  const SecureRepairKeyValueStore(
      [this._storage = const FlutterSecureStorage()]);
  final FlutterSecureStorage _storage;
  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

enum PlanningRepairMode { global, perRow }

/// The status of the planning-currency repair for the current dataset.
enum PlanningRepairStatus {
  /// Case A — no existing budgets/goals: no ambiguity, v30 may proceed.
  notRequired,

  /// Case B — existing rows but no valid confirmed decision yet: v30 blocked.
  needsConfirmation,

  /// A decision exists but the planning row-id set changed since (or it belongs
  /// to another install/user): must re-confirm; v30 blocked.
  stale,

  /// A valid, complete, fingerprint-matching decision exists: v30 unblocked.
  satisfied,
}

/// MALI-026 (Phase-8 B8-2.10 §4) — the single cutover-eligibility contract.
///
/// The future v30 planning-currency cutover executor MUST call this and refuse
/// unless the repair is non-blocking: [PlanningRepairStatus.satisfied] (a valid
/// confirmed decision) or [PlanningRepairStatus.notRequired] (no existing rows,
/// nothing to disambiguate). It refuses for `needsConfirmation` and — crucially
/// — for `stale`: a `stale` decision (the confirmed dataset was replaced/edited
/// after confirmation) is NEVER treated as satisfied, so the executor refuses
/// and the planning mutation guard keeps blocking writes until re-confirmation.
bool mayExecutePlanningCutover(PlanningRepairStatus status) =>
    status == PlanningRepairStatus.satisfied ||
    status == PlanningRepairStatus.notRequired;

class PlanningCurrencyRepairManifest {
  const PlanningCurrencyRepairManifest({
    required this.manifestVersion,
    required this.generatedAtIso,
    required this.installId,
    required this.userId,
    required this.rowSetFingerprint,
    required this.mode,
    required this.globalCurrency,
    required this.perRowCurrency,
  });

  static const int currentVersion = 1;

  final int manifestVersion;
  final String generatedAtIso;
  final String installId;
  final String? userId;

  /// SHA-256 of the sorted budget/goal id set at confirmation time.
  final String rowSetFingerprint;

  final PlanningRepairMode mode;

  /// Confirmed currency for [PlanningRepairMode.global] (applies to every row).
  final String? globalCurrency;

  /// Per-row currency (budget id / goal id → currency) for
  /// [PlanningRepairMode.perRow].
  final Map<String, String> perRowCurrency;

  /// The confirmed currency for a budget/goal id, or null if unknown here.
  String? currencyForId(String id) =>
      mode == PlanningRepairMode.global ? globalCurrency : perRowCurrency[id];

  Map<String, dynamic> toJson() => {
        'manifestVersion': manifestVersion,
        'generatedAtIso': generatedAtIso,
        'installId': installId,
        'userId': userId,
        'rowSetFingerprint': rowSetFingerprint,
        'mode': mode.name,
        'globalCurrency': globalCurrency,
        'perRowCurrency': perRowCurrency,
      };

  String encode() => jsonEncode(toJson());

  static PlanningCurrencyRepairManifest? tryDecode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final j = jsonDecode(raw);
      if (j is! Map<String, dynamic>) return null;
      // future/old → ignore
      if (j['manifestVersion'] != currentVersion) {
        return null;
      }
      final modeName = j['mode'] as String?;
      final mode = PlanningRepairMode.values
          .where((m) => m.name == modeName)
          .cast<PlanningRepairMode?>()
          .firstWhere((_) => true, orElse: () => null);
      if (mode == null) return null;
      final perRow = <String, String>{};
      final rawMap = j['perRowCurrency'];
      if (rawMap is Map) {
        rawMap.forEach((k, v) => perRow['$k'] = '$v');
      }
      return PlanningCurrencyRepairManifest(
        manifestVersion: currentVersion,
        generatedAtIso: j['generatedAtIso'] as String? ?? '',
        installId: j['installId'] as String? ?? '',
        userId: j['userId'] as String?,
        rowSetFingerprint: j['rowSetFingerprint'] as String? ?? '',
        mode: mode,
        globalCurrency: j['globalCurrency'] as String?,
        perRowCurrency: perRow,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Reads/writes the durable repair decision and computes the row-set fingerprint.
class PlanningCurrencyRepairService {
  PlanningCurrencyRepairService({
    required AppDatabase db,
    required RepairKeyValueStore store,
    required String installId,
    String? userId,
  })  : _db = db,
        _store = store,
        _installId = installId,
        _userId = userId;

  final AppDatabase _db;
  final RepairKeyValueStore _store;
  final String _installId;
  final String? _userId;

  /// Namespaced by install so a decision can never bleed across datasets.
  String get _key => 'planning_currency_repair_v1:$_installId';

  Future<List<String>> _ids(String table) async {
    final rows =
        await _db.customSelect('SELECT id FROM $table ORDER BY id;').get();
    return rows.map((r) => r.read<String>('id')).toList(growable: false);
  }

  Future<({List<String> budgetIds, List<String> goalIds})>
      _planningIds() async {
    return (budgetIds: await _ids('budgets'), goalIds: await _ids('goals'));
  }

  /// Semantic fingerprint of the planning objects the currency confirmation is
  /// keyed to — their SET + IDENTITY, NOT their monetary values.
  ///
  /// Explicit policy: a row's currency is ORTHOGONAL to its amount, so editing a
  /// budget/goal amount, or adding a goal contribution (which changes
  /// `saved_amount`), does NOT change the row's currency and MUST NOT invalidate
  /// the confirmation (a currency edit is not implied by a value edit). What DOES
  /// invalidate: adding/deleting a budget/goal, replacing/recreating one (a new
  /// financial object), or a restore/import that brings a DIFFERENT planning
  /// dataset — all change the identity set.
  ///
  /// Identity policy per table:
  /// - goals have an immutable `created_at`, so identity is `(id, created_at)` —
  ///   a recreated/restored goal has a different `created_at`, so a same-id
  ///   replacement of a goal IS detected as stale.
  /// - budgets have NO immutable creation field. category_id is MUTABLE business
  ///   data (a budget can be re-categorised without changing its currency), not
  ///   identity, so it is excluded. We therefore define the budget `id` itself as
  ///   the authoritative logical identity: a same-id budget is intentionally
  ///   treated as the SAME planning object (a restore that brings a DIFFERENT
  ///   dataset under the same budget id is handled separately by the restore
  ///   payload's own scoped repair decision — see PHASE_8 restore preflight — not
  ///   by this live-dataset fingerprint).
  Future<String> computeFingerprint() async {
    final budgets =
        await _db.customSelect('SELECT id FROM budgets ORDER BY id;').get();
    final goals = await _db
        .customSelect('SELECT id, created_at FROM goals ORDER BY id;')
        .get();
    final parts = <String>[
      for (final r in budgets) 'b|${r.read<String>('id')}',
      for (final r in goals)
        'g|${r.read<String>('id')}|${r.read<String>('created_at')}',
    ];
    return sha256.convert(utf8.encode(parts.join('\n'))).toString();
  }

  /// The stored decision, but ONLY if it is valid for the current dataset AND the
  /// row-id set is unchanged; otherwise null.
  Future<PlanningCurrencyRepairManifest?> currentValidManifest() async {
    final m = PlanningCurrencyRepairManifest.tryDecode(await _store.read(_key));
    if (m == null) return null;
    if (m.installId != _installId) return null; // foreign dataset
    if (m.userId != _userId) return null; // different (or added/removed) user
    if (m.rowSetFingerprint != await computeFingerprint()) return null; // stale
    return m;
  }

  Future<PlanningRepairStatus> evaluate() async {
    final ids = await _planningIds();
    if (ids.budgetIds.isEmpty && ids.goalIds.isEmpty) {
      return PlanningRepairStatus.notRequired; // Case A
    }
    final stored =
        PlanningCurrencyRepairManifest.tryDecode(await _store.read(_key));
    if (stored == null) return PlanningRepairStatus.needsConfirmation; // Case B
    if (stored.installId != _installId || stored.userId != _userId) {
      return PlanningRepairStatus.needsConfirmation;
    }
    if (stored.rowSetFingerprint != await computeFingerprint()) {
      return PlanningRepairStatus.stale;
    }
    // perRow decisions must cover every existing planning id.
    if (stored.mode == PlanningRepairMode.perRow) {
      final covered = stored.perRowCurrency.keys.toSet();
      final all = {...ids.budgetIds, ...ids.goalIds};
      if (!covered.containsAll(all)) return PlanningRepairStatus.stale;
    }
    return PlanningRepairStatus.satisfied;
  }

  /// Global confirmation: "all existing budgets and goals use [currency]".
  Future<void> confirmGlobal(String currency) async {
    final code = _requireSupported(currency);
    final manifest = PlanningCurrencyRepairManifest(
      manifestVersion: PlanningCurrencyRepairManifest.currentVersion,
      generatedAtIso: DateTime.now().toUtc().toIso8601String(),
      installId: _installId,
      userId: _userId,
      rowSetFingerprint: await computeFingerprint(),
      mode: PlanningRepairMode.global,
      globalCurrency: code,
      perRowCurrency: const {},
    );
    await _store.write(_key, manifest.encode());
  }

  /// Per-row confirmation: an explicit currency for every existing budget/goal id.
  /// Contributions are NOT listed — they inherit their parent goal's currency.
  Future<void> confirmPerRow(Map<String, String> byId) async {
    final ids = await _planningIds();
    final all = {...ids.budgetIds, ...ids.goalIds};
    final normalized = <String, String>{};
    for (final entry in byId.entries) {
      normalized[entry.key] = _requireSupported(entry.value);
    }
    if (!normalized.keys.toSet().containsAll(all)) {
      throw ArgumentError(
          'per-row repair must assign a currency to every existing budget/goal');
    }
    final manifest = PlanningCurrencyRepairManifest(
      manifestVersion: PlanningCurrencyRepairManifest.currentVersion,
      generatedAtIso: DateTime.now().toUtc().toIso8601String(),
      installId: _installId,
      userId: _userId,
      rowSetFingerprint: await computeFingerprint(),
      mode: PlanningRepairMode.perRow,
      globalCurrency: null,
      perRowCurrency: normalized,
    );
    await _store.write(_key, manifest.encode());
  }

  /// Clear the decision (e.g. user chooses to re-do the repair).
  Future<void> clear() => _store.delete(_key);

  // ── Migration consume API (the future v30 migration calls these) ──────────
  // Each throws if the decision is not currently satisfied — the migration must
  // treat that as BLOCKED/DEFERRED (never fall back to baseCurrencyProvider).

  Future<String> migrationCurrencyForBudget(String id) =>
      _migrationCurrencyForId(id);
  Future<String> migrationCurrencyForGoal(String id) =>
      _migrationCurrencyForId(id);

  /// Contributions inherit the parent goal's repaired currency (no own authority).
  Future<String> migrationCurrencyForContribution(String parentGoalId) =>
      _migrationCurrencyForId(parentGoalId);

  Future<String> _migrationCurrencyForId(String id) async {
    final m = await currentValidManifest();
    if (m == null) {
      throw StateError(
          'planning-currency repair not satisfied — v30 planning migration must '
          'be blocked/deferred (no silent baseCurrencyProvider stamping)');
    }
    final currency = m.currencyForId(id);
    if (currency == null) {
      throw StateError('no confirmed planning currency for row "$id"');
    }
    return currency;
  }

  static String _requireSupported(String currency) {
    final code = currency.trim().toUpperCase();
    if (!isSupportedCurrency(code)) {
      throw UnsupportedCurrencyException(code);
    }
    return code;
  }
}
