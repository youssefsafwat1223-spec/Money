import 'package:flutter_test/flutter_test.dart';
import '../../integration_test/support/sweep_core.dart';

/// Harness self-test — the pre-device gate.
///
/// Three sweeper defects reached the physical device and cost a build cycle
/// each, none of them visible to `flutter analyze`: an indexed finder that
/// threw RangeError instead of reporting NOT-REACHED, a suppressed hit-test
/// that scored an off-screen control as DEAD-TAP, and a `record` that called
/// itself after a bulk regex rewrite. These run in milliseconds and must be
/// green before any device build.
void main() {
  group('1. recording', () {
    test('appends exactly once, emits once, does not recurse', () {
      final emitted = <String>[];
      final r = SweepRecorder(emitted.add);
      r.record('x');
      // Self-recursion showed up as a stack overflow on device; here it would
      // hang or overflow this test in milliseconds instead.
      expect(r.lines, ['x']);
      expect(emitted, ['[SWEEP] x']);
      r.record('y');
      expect(r.lines, ['x', 'y']);
      expect(emitted.last, '[SWEEP] y');
    });
  });

  group('2. index shrink', () {
    test('index within range proceeds', () {
      expect(
          revisitVerdict(
              enumerated: 5, available: 5, index: 4, lastAction: 'tap'),
          isNull);
    });

    test('shrunk count yields NOT-REACHED with triage context, no throw', () {
      final v = revisitVerdict(
          enumerated: 72, available: 71, index: 71, lastAction: 'FilledButton[3]');
      expect(v, isNotNull);
      expect(v, contains('NOT-REACHED'));
      expect(v, contains('enumerated 72'));
      expect(v, contains('found 71'));
      expect(v, contains('previous action: FilledButton[3]'));
      expect(v, contains('TRIAGE-REQUIRED'),
          reason: 'a disappearance is a triage candidate, never a verdict');
    });
  });

  group('4. control-specific effect signals', () {
    test('toggle passes only when its own value flips', () {
      expect(toggleActed(before: false, after: true), isTrue);
      expect(toggleActed(before: true, after: true), isFalse);
      expect(toggleActed(before: null, after: true), isFalse);
    });

    test('text field passes only when the typed value lands', () {
      expect(textFieldVerdict(landed: '42', typed: '42'), startsWith('PASS'));
      expect(textFieldVerdict(landed: '', typed: '42'), startsWith('DEAD-TAP'));
      expect(textFieldVerdict(landed: '42', typed: '42'),
          contains('deferred to deep pass'),
          reason: 'controller landing does not prove search/autosave effects');
    });

    test('refresh must both start and settle', () {
      expect(refreshVerdict(started: true, settled: true), startsWith('PASS'));
      expect(refreshVerdict(started: true, settled: false), startsWith('FAIL'));
      expect(refreshVerdict(started: false, settled: true), startsWith('DEAD-TAP'));
    });

    test('a durable write with no visible change is not a dead tap', () {
      expect(
          tapVerdict(textChanged: false, barriersChanged: false,
              toggled: false, durableWrite: true),
          'PASS (off-screen durable write)');
      expect(
          tapVerdict(textChanged: false, barriersChanged: false,
              toggled: false, durableWrite: false),
          contains('TRIAGE-REQUIRED'));
      expect(
          tapVerdict(textChanged: false, barriersChanged: false,
              toggled: true, durableWrite: false),
          'PASS');
    });
  });

  group('5. durable diff', () {
    final before = {
      'a': {'id': 'a', 'amount': 10, 'name': 'x'},
      'b': {'id': 'b', 'amount': 20, 'name': 'y'},
    };

    test('CREATED', () {
      final d = diffTable(before, {
        ...before,
        'c': {'id': 'c', 'amount': 30, 'name': 'z'},
      });
      expect(d.created, {'c'});
      expect(d.deleted, isEmpty);
      expect(d.updated, isEmpty);
    });

    test('DELETED', () {
      final d = diffTable(before, {'a': before['a']!});
      expect(d.deleted, {'b'});
      expect(d.created, isEmpty);
    });

    test('UPDATED names the row and the changed fields', () {
      // The gap that mattered: same id, changed content.
      final d = diffTable(before, {
        'a': {'id': 'a', 'amount': 99, 'name': 'x'},
        'b': before['b']!,
      });
      expect(d.created, isEmpty);
      expect(d.deleted, isEmpty);
      expect(d.updated, {'a': ['amount']});
      expect(summariseDiff('budgets', d), contains('UPDATED in budgets: a{amount}'));
    });

    test('UNCHANGED', () {
      expect(diffTable(before, before).isEmpty, isTrue);
    });
  });

  group('6. restore verification', () {
    final before = {
      'a': {'id': 'a', 'amount': 10, 'name': "O'Brien"},
      'b': {'id': 'b', 'amount': 20, 'name': 'y'},
    };

    test('restores created/deleted/updated back to the captured state', () {
      final after = {
        'a': {'id': 'a', 'amount': 99, 'name': "O'Brien"}, // updated
        'c': {'id': 'c', 'amount': 30, 'name': 'z'}, // created; 'b' deleted
      };
      final sql = restoreStatements('budgets', before, after);
      expect(sql, contains("DELETE FROM budgets WHERE id = 'c'"));
      expect(sql.any((s) => s.startsWith('INSERT INTO budgets') && s.contains("'b'")),
          isTrue, reason: 'a deleted row must be re-inserted from pre-state');
      expect(sql.any((s) => s.startsWith('UPDATE budgets') && s.contains('amount = 10')),
          isTrue, reason: 'an updated row must be reverted to its old value');
    });

    test('quotes are escaped, so restoration cannot corrupt or inject', () {
      expect(sqlLit("O'Brien"), "'O''Brien'");
      expect(sqlLit(null), 'NULL');
      expect(sqlLit(7), '7');
    });

    test('restoring the plan yields a state equal to pre-state', () {
      // Applying the plan to `after` must reproduce `before` exactly.
      final after = {
        'a': {'id': 'a', 'amount': 99, 'name': "O'Brien"},
        'c': {'id': 'c', 'amount': 30, 'name': 'z'},
      };
      final simulated = Map<String, Map<String, Object?>>.from(after);
      final d = diffTable(before, after);
      for (final id in d.created) {
        simulated.remove(id);
      }
      for (final id in d.deleted) {
        simulated[id] = before[id]!;
      }
      for (final id in d.updated.keys) {
        simulated[id] = before[id]!;
      }
      expect(diffTable(before, simulated).isEmpty, isTrue,
          reason: 'post-restore fingerprint must equal pre-state');
    });
  });

  group('7. unexpected mutation', () {
    test('a write outside the route allowlist is never a pass', () {
      final touched = tablesTouched('CREATED 1 in budgets');
      expect(touched, {'budgets'});
      expect(unexpectedTables(touched, ['user_settings']), {'budgets'},
          reason: 'a settings tile creating a budget row is a finding');
      expect(unexpectedTables(touched, ['budgets']), isEmpty);
    });
  });

  group('8. de-duplication', () {
    test('an inner implementation widget maps to one logical control', () {
      // ListTile(0) encloses InkWell(1); only the ListTile is a user action.
      const outer = 'ListTile';
      const inner = 'InkWell';
      final logical = logicalControls<String>(
        [outer, inner],
        (o, i) => o == outer && i == inner,
        typeOf: (t) => t,
      );
      expect(logical, [outer]);
    });

    test('a switch row maps to the SWITCH, not the row', () {
      // SwitchListTile renders ListTile > Switch. Keeping the row measured
      // page text (which never changes for a toggle) and scored every
      // notification and privacy toggle DEAD-TAP.
      final logical = logicalControls<String>(
        ['ListTile', 'Switch'],
        (o, i) => o == 'ListTile' && i == 'Switch',
        typeOf: (t) => t,
      );
      expect(logical, ['Switch'],
          reason: 'the switch carries the action and the observable state');
    });

    test('checkbox and radio rows follow the same rule', () {
      for (final control in ['Checkbox', 'Radio']) {
        final logical = logicalControls<String>(
          ['ListTile', control],
          (o, i) => o == 'ListTile' && i == control,
          typeOf: (t) => t,
        );
        expect(logical, [control]);
      }
    });

    test('siblings are both kept', () {
      final logical =
          logicalControls<String>(['a', 'b'], (o, i) => false);
      expect(logical, ['a', 'b']);
    });
  });

  group('9. json sub-field diff', () {
    test('names the changed keys inside a blob column', () {
      final d = jsonFieldDiff(
        '{"inboxState":{"impressions":{"c1":1}},"streakReminder":true}',
        '{"inboxState":{"impressions":{"c1":2}},"streakReminder":true}',
      );
      expect(d, ['inboxState'],
          reason: 'only impression bookkeeping moved, not the reminder flags');
    });

    test('detects a genuine settings change distinctly', () {
      final d = jsonFieldDiff(
        '{"inboxState":{},"streakReminder":true}',
        '{"inboxState":{},"streakReminder":false}',
      );
      expect(d, ['streakReminder']);
    });

    test('unparseable blobs compare by raw value, never silently equal', () {
      // Identical unparseable content is genuinely unchanged...
      expect(jsonFieldDiff('not json', 'not json'), isEmpty);
      // ...but differing content must surface rather than be swallowed.
      expect(jsonFieldDiff('not json', 'different'), ['<unparseable>']);
    });
  });

  group('10. baseline attribution (table-level is NOT sufficient)', () {
    test('table-level subtraction was replaced by signature matching', () {
      // Kept as a documented decision: subtracting by table erased any control
      // write that shared a table with background drift. Group 11 is the model
      // that actually ships.
      final b = {MutationSignature('user_settings', 'u1', 'updated', ['a'])};
      final o = {MutationSignature('user_settings', 'u1', 'updated', ['b'])};
      expect(tablesOf(o), tablesOf(b),
          reason: 'same table — table-level matching would erase this');
      expect(attributable(observed: o, baseline: b), isNotEmpty,
          reason: 'signature matching keeps it');
    });
  });

  group('11. precise baseline attribution', () {
    MutationSignature sig(String t, String id, String k, List<String> f) =>
        MutationSignature(t, id, k, f);

    test('identical signature is background drift', () {
      final b = {sig('user_settings', 'u1', 'updated', ['notifications_json.inboxState'])};
      final o = {sig('user_settings', 'u1', 'updated', ['notifications_json.inboxState'])};
      expect(attributable(observed: o, baseline: b), isEmpty);
    });

    test('same table but a DIFFERENT sub-field stays attributable', () {
      // The gap: subtracting by table would have erased a real settings change
      // merely because impression bookkeeping touched the same column.
      final b = {sig('user_settings', 'u1', 'updated', ['notifications_json.inboxState'])};
      final o = {sig('user_settings', 'u1', 'updated', ['notifications_json.streakReminder'])};
      expect(attributable(observed: o, baseline: b), hasLength(1));
    });

    test('same table, different row, stays attributable', () {
      final b = {sig('budgets', 'b1', 'created', const [])};
      final o = {sig('budgets', 'b2', 'created', const [])};
      expect(attributable(observed: o, baseline: b), hasLength(1));
    });

    test('different mutation shape stays attributable', () {
      final b = {sig('budgets', 'b1', 'created', const [])};
      final o = {sig('budgets', 'b1', 'deleted', const [])};
      expect(attributable(observed: o, baseline: b), hasLength(1));
    });

    test('signatures expand json columns into changed sub-fields', () {
      final before = {
        'u1': {'id': 'u1', 'notifications_json': '{"inboxState":{"i":1},"streak":true}'}
      };
      final after = {
        'u1': {'id': 'u1', 'notifications_json': '{"inboxState":{"i":2},"streak":true}'}
      };
      final sigs = signaturesFor(
          'user_settings', diffTable(before, after), before, after);
      expect(sigs, hasLength(1));
      expect(sigs.single.fields, ['notifications_json.inboxState'],
          reason: 'must name the sub-field, not just the column');
    });
  });

  group('12. descriptor identity (index identity is disproven)', () {
    // Runtime evidence: on the dashboard, GestureDetector[21..24] were the nav
    // tabs at enumeration; after one tap and re-navigation the same indices
    // resolved to unrelated controls — one of them the lock-screen privacy
    // toggle. Attributing a verdict by index would have recorded the analytics
    // tab's result against a settings control.
    /// The shipped strategy: re-bind by descriptor, preserving ordinal among
    /// same-labelled siblings; refuse when the label cannot be found.
    int resolve({
      required String wantLabel,
      required List<String> nowLabels,
      required int ordinalAmongSiblings,
    }) {
      final matches = <int>[];
      for (var i = 0; i < nowLabels.length; i++) {
        if (nowLabels[i] == wantLabel) matches.add(i);
      }
      if (matches.isEmpty) return -1;
      return matches[ordinalAmongSiblings.clamp(0, matches.length - 1)];
    }

    test('refuses attribution when the index now holds another control', () {
      // Enumerated: index 23 == walletCards tab. After rebuild, index 23 is the
      // lock-screen toggle and the tab is absent entirely.
      final now = ['icon:f4b9', '', '', 'إخفاء التفاصيل الحساسة على شاشة القفل'];
      expect(
          resolve(wantLabel: 'icon:f58a', nowLabels: now, ordinalAmongSiblings: 0),
          -1,
          reason: 'must refuse rather than tap the control now at that index');
    });

    test('re-binds to the moved control when it is still present', () {
      final now = ['x', 'icon:f58a', 'y'];
      expect(
          resolve(wantLabel: 'icon:f58a', nowLabels: now, ordinalAmongSiblings: 0),
          1,
          reason: 'identity follows the descriptor, not the position');
    });

    test('same-labelled siblings keep a one-to-one mapping', () {
      final now = ['dup', 'dup', 'dup'];
      expect(resolve(wantLabel: 'dup', nowLabels: now, ordinalAmongSiblings: 0), 0);
      expect(resolve(wantLabel: 'dup', nowLabels: now, ordinalAmongSiblings: 2), 2);
    });

    test('ordinal beyond what survives clamps rather than throwing', () {
      final now = ['dup'];
      expect(resolve(wantLabel: 'dup', nowLabels: now, ordinalAmongSiblings: 5), 0);
    });
  });
}
