// WP-5 grep guard: no blind overwrite path remains in the sync push code.
//
//  1. Every PostgREST `.update(` in the push services carries a guard
//     predicate in the SAME statement (revision / updated_at / not-deleted).
//     The one deliberate exception is the settings field-LWW patch and the
//     consent revocation (`updateByServerId`): settings are last-writer-wins
//     per field by design (consent excluded) and are never deleted.
//  2. The CAS code paths (capability `revision_cas`) never fall back to an
//     upsert or a plain update: they go only through the sync_* RPCs.
//  3. No client code clears `deleted_at` on a tombstone, except the plan-link
//     set-semantics re-link (pre-existing, WP-9).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _services = [
  'lib/features/capture/services/ledger_push_service.dart',
  'lib/features/planning_sync/services/accounts_push_service.dart',
  'lib/features/planning_sync/services/planning_push_service.dart',
  'lib/features/planning_sync/services/planning_child_sync_service.dart',
];

String _read(String p) => File(p).readAsStringSync();

void main() {
  test('every PostgREST .update( is guarded in its own statement', () {
    final guards = [
      RegExp(r"\.eq\(\s*'revision'"),
      RegExp(r"\.eq\(\s*'updated_at'"),
      RegExp(r"\.isFilter\(\s*'deleted_at'"),
    ];
    // Deliberate, documented exceptions (by enclosing method):
    //  - updateByServerId: the settings field-LWW patch and the consent
    //    revocation (settings are last-writer-wins per field, consent excluded,
    //    and the row is never deleted).
    //  - upsertPlanLink: pre-existing plan-link set-semantics re-link (WP-9).
    const allowedMethods = {'updateByServerId', 'upsertPlanLink'};
    final unguarded = <String>[];
    for (final path in _services) {
      final src = _read(path);
      for (final m in RegExp(r'(?<!_cas)\.update\(').allMatches(src)) {
        final stmt = src.substring(m.start, src.indexOf(';', m.start));
        if (guards.any((g) => g.hasMatch(stmt))) continue;
        final methods = RegExp(r'\n  (?:@override\n  )?Future<[^\n]*?>\s+(\w+)\(')
            .allMatches(src.substring(0, m.start))
            .toList();
        final method = methods.isEmpty ? '?' : methods.last.group(1)!;
        if (!allowedMethods.contains(method)) unguarded.add('$path ($method)');
      }
    }
    expect(unguarded, isEmpty,
        reason: 'a blind update was added: guard it (CAS revision, updated_at '
            'or not-deleted) or route it through the sync_* RPCs');
  });

  test('the CAS code paths never upsert or blind-update', () {
    for (final path in _services.take(3)) {
      final src = _read(path);
      final start = src.indexOf('// ── WP-5: revision CAS');
      expect(start, greaterThan(-1), reason: path);
      final end = src.indexOf('  /// A guarded', start);
      final body = src.substring(start, end == -1 ? src.length : end);
      // Settings field LWW is the documented exception, in its own method.
      final cut = body.indexOf('Future<_PlanningPushOutcome> _pushSettingsLww(');
      final checked = cut == -1 ? body : body.substring(0, cut);
      for (final forbidden in [
        '.upsert(',
        'upsertAccount(',
        '_remoteSink.upsert(',
        'updateByServerId(',
        'guardedUpdate',
        '.from(',
      ]) {
        expect(checked.contains(forbidden), isFalse,
            reason: '$path: CAS path must use only the sync_* RPCs, found $forbidden');
      }
      expect(checked, contains('_cas.'));
    }
  });

  test('no client code un-deletes a tombstone, apart from the plan-link '
      'set-semantics re-link', () {
    for (final path in _services) {
      final src = _read(path);
      if (path.endsWith('planning_child_sync_service.dart')) continue;
      expect(RegExp(r"'deleted_at'\s*:\s*null").hasMatch(src), isFalse,
          reason: path);
    }
  });
}
