/// Pure decision logic for the exhaustive control sweeper.
///
/// Extracted from the integration test so it can be proven locally in
/// milliseconds instead of in a 7-minute device cycle. Three harness defects
/// reached the device before this existed — an indexed-finder RangeError, a
/// suppressed hit-test scored as DEAD-TAP, and a `record` that called itself
/// after a bulk regex rewrite. None of them were visible to `flutter analyze`,
/// because none of them are type errors.
///
/// Everything here is deterministic and free of Flutter bindings; the sweeper
/// supplies the widget-tree facts and this decides what they mean.
library;

import 'dart:convert';

/// Appends once and emits once. The self-recursion defect lived in a two-line
/// function whose only invariant is this one.
class SweepRecorder {
  SweepRecorder(this.emit);
  final void Function(String) emit;
  final List<String> lines = <String>[];

  void record(String line) {
    lines.add(line);
    emit('[SWEEP] $line');
  }
}

/// What a control's index means on a revisit. `Finder.at(i)` THROWS rather than
/// matching nothing when the count has shrunk, so the bound must be checked
/// before indexing, and a shrink is a triage candidate — never a verdict.
String? revisitVerdict({
  required int enumerated,
  required int available,
  required int index,
  required String lastAction,
}) {
  if (index < available) return null; // reachable; proceed
  return 'NOT-REACHED (enumerated $enumerated of this type, found $available '
      'on revisit; previous action: $lastAction) TRIAGE-REQUIRED';
}

/// Row-level changes for one table. Ids alone cannot see an in-place UPDATE,
/// which is how consent flags, amounts and revisions change.
class TableDiff {
  TableDiff(this.created, this.deleted, this.updated);
  final Set<String> created;
  final Set<String> deleted;
  final Map<String, List<String>> updated; // id -> changed columns

  bool get isEmpty => created.isEmpty && deleted.isEmpty && updated.isEmpty;
}

TableDiff diffTable(
  Map<String, Map<String, Object?>> before,
  Map<String, Map<String, Object?>> after,
) {
  final created = after.keys.toSet().difference(before.keys.toSet());
  final deleted = before.keys.toSet().difference(after.keys.toSet());
  final updated = <String, List<String>>{};
  for (final id in after.keys.toSet().intersection(before.keys.toSet())) {
    final b = before[id]!, a = after[id]!;
    final changed = <String>[];
    for (final k in {...a.keys, ...b.keys}) {
      if ('${b[k]}' != '${a[k]}') changed.add(k);
    }
    if (changed.isNotEmpty) updated[id] = changed..sort();
  }
  return TableDiff(created, deleted, updated);
}

String summariseDiff(String table, TableDiff d) {
  final parts = <String>[];
  if (d.created.isNotEmpty) parts.add('CREATED ${d.created.length} in $table');
  if (d.deleted.isNotEmpty) parts.add('DELETED ${d.deleted.length} in $table');
  if (d.updated.isNotEmpty) {
    final shown = d.updated.entries
        .take(3)
        .map((e) => '${e.key}{${e.value.join(",")}}')
        .join(' ');
    parts.add('UPDATED in $table: $shown'
        '${d.updated.length > 3 ? " +${d.updated.length - 3}" : ""}');
  }
  return parts.join('; ');
}

/// Tables named by a summary, for checking against what a route may write.
Set<String> tablesTouched(String summary) =>
    RegExp(r'in (\w+)').allMatches(summary).map((m) => m.group(1)!).toSet();

/// A durable write outside the route's allowed set is a finding, not a pass:
/// a settings tile that creates a budget row has done something wrong.
Set<String> unexpectedTables(Set<String> touched, List<String> allowed) =>
    touched.difference(allowed.toSet());

String sqlLit(Object? v) {
  if (v == null) return 'NULL';
  if (v is num) return '$v';
  if (v is bool) return v ? '1' : '0';
  if (v is List<int>) {
    return "X'${v.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}'";
  }
  return "'${v.toString().replaceAll("'", "''")}'";
}

/// SQL that returns [table] to exactly its captured pre-state: drop what the
/// control created, re-insert what it deleted with the ORIGINAL column values,
/// and revert what it changed. Restoration from captured state, not invention.
List<String> restoreStatements(
  String table,
  Map<String, Map<String, Object?>> before,
  Map<String, Map<String, Object?>> after,
) {
  final d = diffTable(before, after);
  final out = <String>[];
  for (final id in d.created) {
    out.add('DELETE FROM $table WHERE id = ${sqlLit(id)}');
  }
  for (final id in d.deleted) {
    final row = before[id]!;
    out.add('INSERT INTO $table (${row.keys.join(', ')}) '
        'VALUES (${row.keys.map((k) => sqlLit(row[k])).join(', ')})');
  }
  for (final id in d.updated.keys) {
    final row = before[id]!;
    final set = row.keys
        .where((k) => k != 'id')
        .map((k) => '$k = ${sqlLit(row[k])}')
        .join(', ');
    out.add('UPDATE $table SET $set WHERE id = ${sqlLit(id)}');
  }
  return out;
}

/// A toggle's effect is its own value flipping; the surrounding copy never
/// changes, so page-text diffing scored every switch as a dead tap.
bool toggleActed({bool? before, bool? after}) =>
    before != null && after != null && before != after;

String textFieldVerdict({String? landed, required String typed}) {
  if (landed == null) return 'PASS (no controller)';
  return landed.contains(typed)
      ? 'PASS (accepts input; side effects deferred to deep pass)'
      : 'DEAD-TAP (input rejected)';
}

/// The drag is only the trigger: the callback must start AND settle.
String refreshVerdict({required bool started, required bool settled}) {
  if (started && settled) return 'PASS (refresh ran and settled)';
  if (started) return 'FAIL (refresh never settled)';
  return 'DEAD-TAP (callback never started)';
}

/// Whether a tap did anything at all, given every signal available. A durable
/// write with no visible change is a successful off-screen mutation.
String tapVerdict({
  required bool textChanged,
  required bool barriersChanged,
  required bool toggled,
  required bool durableWrite,
}) {
  if (textChanged || barriersChanged || toggled) return 'PASS';
  if (durableWrite) return 'PASS (off-screen durable write)';
  return 'DEAD-TAP (no visible change, no durable write) TRIAGE-REQUIRED';
}

/// Keeps only OUTERMOST candidates: a ListTile renders an InkWell, so counting
/// both would inflate the denominator with something that is not a distinct
/// user action. [contains] reports whether `outer` encloses `inner`.
List<T> logicalControls<T>(
  List<T> candidates,
  bool Function(T outer, T inner) contains,
) =>
    candidates
        .where((inner) => !candidates.any((outer) =>
            !identical(outer, inner) && contains(outer, inner)))
        .toList();


/// Changed keys inside a JSON blob column. Reporting only "notifications_json
/// changed" cannot distinguish campaign-impression bookkeeping from a genuine
/// settings rewrite, so the blob is diffed key-by-key (one level deep, with
/// nested maps compared by encoded value).
List<String> jsonFieldDiff(Object? before, Object? after) {
  Map<String, Object?> decode(Object? v) {
    if (v == null) return const {};
    try {
      final d = jsonDecode(v.toString());
      return d is Map<String, Object?> ? d : {'<non-map>': d};
    } catch (_) {
      return {'<unparseable>': v.toString()};
    }
  }

  final b = decode(before), a = decode(after);
  final changed = <String>[];
  for (final k in {...b.keys, ...a.keys}) {
    if (jsonEncode(b[k]) != jsonEncode(a[k])) changed.add(k);
  }
  return changed..sort();
}

/// One durable change, identified precisely enough to compare against a no-tap
/// observation: table, row, kind, and — for blob columns — the sub-fields that
/// moved. Matching on table alone would erase a real finding whenever any
/// background writer happened to touch the same table.
class MutationSignature {
  MutationSignature(this.table, this.rowId, this.kind, List<String> fields)
      // Copy before sorting: callers legitimately pass `const []`,
      // and sorting that in place throws at runtime.
      : fields = List<String>.unmodifiable([...fields]..sort());
  final String table;
  final String rowId;
  final String kind; // created | deleted | updated
  final List<String> fields;

  String get key => '$table/$rowId/$kind/${fields.join(",")}';

  @override
  bool operator ==(Object other) =>
      other is MutationSignature && other.key == key;
  @override
  int get hashCode => key.hashCode;
  @override
  String toString() => key;
}

/// Signatures for one table's diff, expanding `*_json` columns into the keys
/// that actually changed inside them.
List<MutationSignature> signaturesFor(
  String table,
  TableDiff d,
  Map<String, Map<String, Object?>> before,
  Map<String, Map<String, Object?>> after,
) {
  final out = <MutationSignature>[];
  for (final id in d.created) {
    out.add(MutationSignature(table, id, 'created', const []));
  }
  for (final id in d.deleted) {
    out.add(MutationSignature(table, id, 'deleted', const []));
  }
  for (final e in d.updated.entries) {
    final fields = <String>[];
    for (final col in e.value) {
      if (col.endsWith('_json')) {
        final sub = jsonFieldDiff(before[e.key]?[col], after[e.key]?[col]);
        fields.addAll(sub.map((k) => '$col.$k'));
      } else {
        fields.add(col);
      }
    }
    out.add(MutationSignature(table, e.key, 'updated', fields));
  }
  return out;
}

/// What the control is actually responsible for. A signature is background
/// drift ONLY when an identical one (same table, row, kind and sub-fields) was
/// observed with no interaction. Anything else — including an extra impression
/// on top of a baseline impression — stays attributable to the control.
Set<MutationSignature> attributable({
  required Set<MutationSignature> observed,
  required Set<MutationSignature> baseline,
}) =>
    observed.difference(baseline);

/// Tables named by a set of signatures.
Set<String> tablesOf(Set<MutationSignature> s) => s.map((m) => m.table).toSet();
