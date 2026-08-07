// Phase-7 Batch-2-A (MALI-029) — central bounded-ID SQLite lookup primitive.
//
// Sync/pull batching replaces per-row `WHERE x = ?` SELECT loops with a single
// `WHERE x IN (?, ?, …)` prefetch. That IN-list is bounded by SQLite's
// `SQLITE_MAX_VARIABLE_NUMBER`, so a page of identifiers must be split into
// chunks and each chunk bound as real placeholders — never interpolated into
// the SQL text. This file is the ONE place that owns the chunk size and the
// chunking/binding contract, so every converted service uses the same safe path.
//
// Bound variables only. There is deliberately no helper here that concatenates
// identifiers into SQL text.
import 'package:drift/drift.dart';

import 'app_database.dart';

/// Maximum number of bound identifiers per lookup statement.
///
/// Rationale: the lowest `SQLITE_MAX_VARIABLE_NUMBER` we target is **999**
/// (SQLite < 3.32.0; SQLCipher / sqlite3mc builds inherit whatever the bundled
/// amalgamation was compiled with, and we do NOT assume the raised 32766 limit).
/// 500 leaves >49% headroom in the same statement for the caller's own
/// owner/admission-scoping and cursor bindings, and stays valid on any
/// conservative or embedded build. It also comfortably exceeds the 200-row sync
/// page size, so production pull pages resolve in a single chunk while
/// migration/backfill paths that pass more identifiers still chunk safely.
const int kSqliteMaxLookupChunk = 500;

/// Splits [ids] into deterministically-ordered chunks of at most [chunkSize].
///
/// - Empty input returns `const []` so the caller issues **no** query.
/// - [dedupe] (default true) drops duplicate identifiers **before** chunking,
///   preserving first-seen order — the SELECT result is a set keyed by id, so a
///   repeated identifier only wastes a bind slot. Callers that need to preserve
///   duplicate multiplicity (rare) pass `dedupe: false`.
/// - Order is stable: within the (optionally de-duplicated) sequence, chunk `k`
///   holds the elements at `[k*chunkSize, (k+1)*chunkSize)`.
List<List<T>> chunkForLookup<T>(
  Iterable<T> ids, {
  int chunkSize = kSqliteMaxLookupChunk,
  bool dedupe = true,
}) {
  assert(chunkSize > 0, 'chunkSize must be positive');
  // A Dart `Set` is insertion-ordered (LinkedHashSet), so dedup preserves
  // first-seen order for deterministic chunk boundaries.
  final Iterable<T> source = dedupe ? Set<T>.of(ids) : ids;
  final list = source is List<T> ? source : source.toList(growable: false);
  if (list.isEmpty) return const [];
  final chunks = <List<T>>[];
  for (var start = 0; start < list.length; start += chunkSize) {
    final end =
        (start + chunkSize) < list.length ? start + chunkSize : list.length;
    chunks.add(list.sublist(start, end));
  }
  return chunks;
}

/// Builds the `?, ?, …` placeholder fragment for [count] bound variables.
///
/// [count] must be positive — an empty IN list is never a valid SQL fragment,
/// and [chunkForLookup] already guarantees non-empty chunks.
String boundPlaceholders(int count) {
  assert(count > 0, 'placeholder count must be positive');
  return List.filled(count, '?').join(', ');
}

/// Runs [sql] once per bounded chunk of [ids] and concatenates the resulting
/// rows. This is the single supported way to resolve a batch of identifiers to
/// their local rows.
///
/// - [sql] receives the placeholder fragment for the current chunk (e.g.
///   `"?, ?, ?"`) and must embed it inside a bound IN clause, e.g.
///   `(ph) => 'SELECT id, server_id FROM accounts WHERE server_id IN ($ph)'`.
///   Identifiers are NEVER interpolated into the SQL text.
/// - [bindings] maps the chunk's identifier [Variable]s to the full positional
///   variable list for the statement, letting the caller make owner/admission
///   scoping explicit (e.g. `(idVars) => [...idVars, Variable.withString(owner)]`
///   for `… WHERE server_id IN ($ph) AND user_id = ?`). When omitted the chunk
///   identifiers are the only bound variables, in order.
/// - Empty (or all-duplicate-then-empty) [ids] issues no query and returns
///   `const []`.
Future<List<QueryRow>> selectByIdChunks(
  AppDatabase db,
  Iterable<String> ids, {
  required String Function(String placeholders) sql,
  List<Variable> Function(List<Variable> idVars)? bindings,
  int chunkSize = kSqliteMaxLookupChunk,
  bool dedupe = true,
}) async {
  final chunks = chunkForLookup(ids, chunkSize: chunkSize, dedupe: dedupe);
  if (chunks.isEmpty) return const [];
  final rows = <QueryRow>[];
  for (final chunk in chunks) {
    final idVars = [for (final id in chunk) Variable<String>(id)];
    final variables = bindings == null ? idVars : bindings(idVars);
    final chunkRows =
        await db.customSelect(sql(boundPlaceholders(chunk.length)),
            variables: variables).get();
    rows.addAll(chunkRows);
  }
  return rows;
}

/// Resolves [ids] to a `id → row` map via one bounded lookup per chunk. Callers
/// that just need a map keyed by a single column use this instead of hand-rolling
/// the row loop. [keyColumn] is read from each row as the map key; the whole
/// [QueryRow] is the value so callers can read any selected column.
///
/// A duplicate key across chunks keeps the **last** row seen (chunks are
/// processed in order); within the set-keyed result this does not arise because
/// [keyColumn] is expected to be unique per row.
Future<Map<String, QueryRow>> lookupRowsById(
  AppDatabase db,
  Iterable<String> ids, {
  required String Function(String placeholders) sql,
  required String keyColumn,
  List<Variable> Function(List<Variable> idVars)? bindings,
  int chunkSize = kSqliteMaxLookupChunk,
  bool dedupe = true,
}) async {
  final rows = await selectByIdChunks(
    db,
    ids,
    sql: sql,
    bindings: bindings,
    chunkSize: chunkSize,
    dedupe: dedupe,
  );
  final map = <String, QueryRow>{};
  for (final row in rows) {
    map[row.read<String>(keyColumn)] = row;
  }
  return map;
}
