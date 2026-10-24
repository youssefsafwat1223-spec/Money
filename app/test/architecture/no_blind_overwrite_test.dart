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

// One scanner is shared with the tombstone contract test in this directory.
// Tokenizing strings/comments and consuming balanced argument lists keeps a
// neighbouring ternary branch (or a guard inside a payload) out of this chain.
class PostgrestUpdate {
  const PostgrestUpdate(this.start, this.end, this.payload, this.text, this.guarded, this.updateStart);
  final int start;
  final int end;
  final String payload;
  final String text;
  final bool guarded;
  final int updateStart;
}

final _dartLexical = RegExp(
  r"""//[^\n]*|/\*[\s\S]*?\*/|r?'(?:\\.|[^'\\])*'|r?"(?:\\.|[^"\\])*"|[A-Za-z_$][\w$]*|[^\s]""",
);

String withoutDartComments(String source) => source.replaceAllMapped(
    _dartLexical, (m) => m[0]!.startsWith('//') || m[0]!.startsWith('/*')
        ? m[0]!.replaceAll(RegExp(r'[^\n]'), ' ') : m[0]!);

List<PostgrestUpdate> postgrestUpdates(String source) {
  final tokens = _dartLexical.allMatches(source).where((m) =>
      !m[0]!.startsWith('//') && !m[0]!.startsWith('/*')).toList();
  String token(int index) => tokens[index][0]!;
  int close(int open) {
    var depth = 0;
    for (var i = open; i < tokens.length; i++) {
      if (token(i) == '(') depth++;
      if (token(i) == ')') {
        depth--;
        if (depth == 0) return i;
      }
    }
    throw StateError('Unclosed call at ${tokens[open].start}');
  }
  bool column(int index, String name) =>
      token(index) == "'$name'" || token(index) == '"$name"';
  final updates = <PostgrestUpdate>[];
  for (var root = 0; root + 2 < tokens.length; root++) {
    if (token(root) != '.' || token(root + 1) != 'from' ||
        token(root + 2) != '(') {
      continue;
    }
    final calls = <({String name, int open, int end, int dot})>[];
    var cursor = root;
    while (cursor + 2 < tokens.length && token(cursor) == '.' &&
        token(cursor + 2) == '(') {
      final end = close(cursor + 2);
      calls.add((name: token(cursor + 1), open: cursor + 2, end: end,
          dot: tokens[cursor].start));
      cursor = end + 1;
    }
    for (var n = 0; n < calls.length; n++) {
      final call = calls[n];
      if (call.name != 'update') continue;
      final guarded = calls.skip(n + 1).any((guard) {
        final first = guard.open + 1;
        if (first + 2 >= guard.end || token(first + 1) != ',') return false;
        return (guard.name == 'eq' &&
                (column(first, 'revision') || column(first, 'updated_at'))) ||
            (guard.name == 'isFilter' && column(first, 'deleted_at') &&
                token(first + 2) == 'null');
      });
      final start = tokens[root].start;
      final end = tokens[calls.last.end].end;
      updates.add(PostgrestUpdate(start, end,
          tokens.sublist(call.open + 1, call.end).map((m) => m[0]!).join(),
          source.substring(start, end), guarded, call.dot));
    }
  }
  return updates;
}

bool _hasCodeTokens(List<String> words, String code) {
  final expected = _dartLexical.allMatches(code).map((m) => m[0]!).toList();
  for (var i = 0; i + expected.length <= words.length; i++) {
    if (List.generate(expected.length, (n) => words[i + n] == expected[n])
        .every((equal) => equal)) {
      return true;
    }
  }
  return false;
}

Iterable<Match> _factoryDeclarations(List<String> words, RegExp shape) sync* {
  for (var i = 0; i < words.length; i++) {
    if (words[i] != 'factory') continue;
    final match = shape.matchAsPrefix(words.skip(i).join());
    if (match != null) yield match;
  }
}

// Fail closed on every lexical .update outside a concrete HTTP chain. In
// particular a saved PostgREST builder is not silently lost by the chain scan.
// The semantic constructors below are proved by their exact pure factory body
// and bounded call position, not an uppercase receiver or class-name allowlist.
List<int> unclassifiedUpdateOffsets(String source) {
  final tokens = _dartLexical.allMatches(source).where((m) =>
      !m[0]!.startsWith('//') && !m[0]!.startsWith('/*')).toList();
  final words = tokens.map((m) => m[0]!).toList();
  final tracked = postgrestUpdates(source).map((u) => u.updateStart).toSet();
  final factories = _factoryDeclarations(words, RegExp(
      r"factory(\w+)\.update\(Stringtable,StringserverId,Map<String,dynamic>row\)=>"
      r"\1\._\('updateByServerId',table,serverId,null,row,null\);"))
      .map((m) => m[1]!).where((name) => _hasCodeTokens(words,
          '$name._(this.method,this.table,this.target,this.guard,'
          'Map<String,dynamic>body,this.deletedAt):'
          'body=_freezeWire(body)as Map<String,Object?>;')).toSet();
  final observations = <String>{};
  if (_hasCodeTokens(words, "import '../../../data/sync/revision_cas.dart';")) {
    final casWords = _dartLexical.allMatches(_read('lib/data/sync/revision_cas.dart'))
        .where((m) => !m[0]!.startsWith('//') && !m[0]!.startsWith('/*'))
        .map((m) => m[0]!).toList();
    for (final factory in _factoryDeclarations(casWords, RegExp(
        r"factory(\w+)\.update\(\{requiredStringtable,requiredStringepoch,"
        r"requiredStringopId,requiredStringserverId,requiredintexpectedRevision,"
        r"requiredMap<String,dynamic>patch,\}\)=>\1\._\('sync_cas_update',"
        r"_updateParams\(table,epoch,opId,serverId,expectedRevision,patch\)\);"))) {
      final name = factory[1]!;
      if (_hasCodeTokens(casWords, '$name._(this._rpc,Map<String,dynamic>params):'
          '_expected=_freezeJson(params,<Object>[])as Map<String,Object?>;')) {
        observations.add(name);
      }
    }
  }
  final rpcEngine = _hasCodeTokens(words,
      'RevisionCasEngine get _cas => RevisionCasEngine(');
  final unresolved = <int>[];
  for (var i = 1; i + 2 < words.length; i++) {
    if (words[i] != '.' || words[i + 1] != 'update' || words[i + 2] != '(') {
      continue;
    }
    if (tracked.contains(tokens[i].start)) continue;
    final receiver = words[i - 1];
    // This is the original exact CAS engine route, still checked separately
    // below for RPC-only dispatch; it is not a PostgREST builder alias.
    if (receiver == '_cas' && rpcEngine) continue;
    if (factories.contains(receiver) && i >= 3 &&
        (words[i - 2] == 'factory' ||
            (words[i - 3] == 'command' && words[i - 2] == ':'))) {
      continue;
    }
    if (observations.contains(receiver) && i >= 3 &&
        words[i - 3] == '_mutate' && words[i - 2] == '(') {
      const parameters = 'table:table,epoch:epoch,opId:opId,serverId:serverId,'
          'expectedRevision:expectedRevision,patch:patch';
      final tail = words.skip(i - 1).join();
      if (tail.startsWith('$receiver.update($parameters),'
          '()=>delegate.casUpdate($parameters))')) {
        continue;
      }
    }
    unresolved.add(tokens[i].start);
  }
  return unresolved;
}

// These are the original, documented exceptions for classified HTTP chains.
// Unresolved aliases never inherit a method exception, even if guarded.
List<String> _unguardedUpdates(String src) {
  src = withoutDartComments(src);
  const allowedMethods = {'updateByServerId', 'upsertPlanLink'};
  final unguarded = [
    for (final offset in unclassifiedUpdateOffsets(src)) 'unclassified update at $offset',
  ];
  for (final update in postgrestUpdates(src)) {
    if (update.guarded) continue;
    final methods = RegExp(r'\n  (?:@override\n  )?Future<[^\n]*?>\s+(\w+)\(')
        .allMatches(src.substring(0, update.start)).toList();
    final method = methods.isEmpty ? '?' : methods.last.group(1)!;
    if (!allowedMethods.contains(method)) unguarded.add(method);
  }
  return unguarded;
}

void main() {
  test('every PostgREST .update( is guarded in its own statement', () {
    final unguarded = <String>[];
    for (final path in _services) {
      final src = _read(path);
      expect(postgrestUpdates(src), isNotEmpty, reason: path);
      unguarded.addAll(_unguardedUpdates(src).map((method) => '$path ($method)'));
    }
    expect(unguarded, isEmpty,
        reason: 'a blind update was added: guard it (CAS revision, updated_at '
            'or not-deleted) or route it through the sync_* RPCs');
  });

  test('exact semantic constructors are classified without masking SDK writes', () {
    final src = _read(_services[2]);
    expect(unclassifiedUpdateOffsets(src), isEmpty);
    expect(_unguardedUpdates('$src\n'
        "Future<void> addedBlindWrite() async {\n"
        "  await client.from('parents').update(row).eq('id', id);\n}\n"),
        hasLength(1));
    // Changing the proved command factory invalidates its declaration AND uses.
    final changedFactory = src.replaceFirst(
        "_ParentCommand._('updateByServerId', table, serverId, null, row, null)",
        "_ParentCommand._('different', table, serverId, null, row, null)");
    expect(changedFactory, isNot(src));
    expect(unclassifiedUpdateOffsets(changedFactory), isNotEmpty);
  });

  test('unknown aliases and factory lookalikes fail closed, including in old exceptions', () {
    for (final source in [
      "final table = client.from('parents'); table.update(row).eq('id', id);",
      "final table = client.from('parents'); table.update(row).eq('updated_at', base);",
      "Unknown.update(row).eq('updated_at', base);",
      r"""
"factory Fake.update(String table,String serverId,Map<String,dynamic> row) =>
Fake._('updateByServerId',table,serverId,null,row,null);
Fake._(this.method,this.table,this.target,this.guard,Map<String,dynamic> body,this.deletedAt):
body=_freezeWire(body)as Map<String,Object?>;" command: Fake.update(table,id,row);
""",
      "factory Lookalike.update(Map body) => client.from('p').update(body);",
      "\n  Future<void> updateByServerId() async {\n"
          "  final table = client.from('p'); await table.update(row);\n}",
      "\n  Future<void> upsertPlanLink() async {\n"
          "  await Unknown.update(row).eq('updated_at', base);\n}",
    ]) {
      expect(unclassifiedUpdateOffsets(source), isNotEmpty, reason: source);
      expect(_unguardedUpdates(source), isNotEmpty, reason: source);
    }
  });

  test('a guard in a sibling branch or nested argument cannot hide a blind write', () {
    for (final source in [
      "condition ? client.from('p').update(row).eq('id', id) "
          ": client.from('p').update(row).eq('updated_at', base);",
      "condition ? client.from('p').update(row).eq('updated_at', base) "
          ": client.from('p').update(row).eq('id', id);",
      "client.from('p').update(build(other.eq('updated_at', base)))"
          ".eq('id', id);",
      "client.from('p').update(row).eq('id', id)"
          "/* .eq('updated_at', base) */;",
    ]) {
      expect(_unguardedUpdates(source), hasLength(1), reason: source);
    }
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
