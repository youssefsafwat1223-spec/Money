@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The committed tree must be self-contained.
///
/// ## Why this exists
///
/// Every test gate in this repository runs against the WORKING TREE. That says
/// nothing about whether HEAD is complete, and during the 2026-08-29 audit that
/// gap hid three real breaks:
///
///   1. `process-notification-retries/index.ts` was committed importing
///      `./process_one.ts`, which was never staged — a committed Edge Function
///      importing a file that does not exist in the committed tree;
///   2. migrations 0084, 0085 and 0086 existed only in the tree, leaving the
///      committed sequence jumping 0083 → 0087, so anyone applying migrations
///      from HEAD would silently skip three security and data-integrity
///      migrations;
///   3. `verify_ios_release_artifact.sh` was untracked, so a committed test
///      could not load at all on a clean checkout.
///
/// In each case the suite was green in the tree and broken at HEAD. That is the
/// worst shape a failure can take: the gate reports success about code that is
/// not the code being shipped.
///
/// These checks are cheap and run against `git ls-files`, so they see exactly
/// what a fresh clone would get.
void main() {
  final repoRoot = Directory.current.parent.path;

  List<String> tracked(String pattern) {
    final r = Process.runSync(
      'git',
      ['ls-files', pattern],
      workingDirectory: repoRoot,
      stdoutEncoding: utf8,
    );
    return (r.stdout as String)
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
  }

  bool isTracked(String repoRelPath) =>
      tracked(repoRelPath).contains(repoRelPath);

  group('the migration sequence has no holes', () {
    test('every number from the first to the last is present', () {
      // A gap is worse than a missing file: migrations are applied in order, so
      // a hole means whoever deploys silently skips whatever was in it.
      final nums = tracked('supabase/migrations/*.sql')
          .map((p) => RegExp(r'/(\d{4})_').firstMatch(p)?.group(1))
          .whereType<String>()
          .map(int.parse)
          .toList()
        ..sort();

      expect(nums, isNotEmpty, reason: 'no migrations are tracked at all');

      final missing = <int>[];
      for (var n = nums.first; n <= nums.last; n++) {
        if (!nums.contains(n)) missing.add(n);
      }

      expect(missing, isEmpty,
          reason: 'the COMMITTED migration sequence skips '
              '${missing.map((n) => n.toString().padLeft(4, '0')).join(', ')}. '
              'Those files may exist in your working tree — commit them. A '
              'deploy from HEAD applies what HEAD contains, not what you can '
              'see locally.');
    });

    test('no two migrations share a number', () {
      final nums = tracked('supabase/migrations/*.sql')
          .map((p) => RegExp(r'/(\d{4})_').firstMatch(p)?.group(1))
          .whereType<String>()
          .toList();
      final dupes = <String>{};
      final seen = <String>{};
      for (final n in nums) {
        if (!seen.add(n)) dupes.add(n);
      }
      expect(dupes, isEmpty,
          reason: 'two migrations claim the same number: ${dupes.join(', ')} — '
              'apply order becomes filesystem-dependent');
    });
  });

  group('committed code does not import uncommitted files', () {
    test('every relative Deno import resolves to a tracked file', () {
      final broken = <String>[];
      for (final f in tracked('supabase/functions/*.ts')) {
        final src = File('$repoRoot/$f').readAsStringSync();
        final dir = f.substring(0, f.lastIndexOf('/'));
        for (final m
            in RegExp(r"""from ['"](\./[A-Za-z0-9_./-]+\.ts)['"]""").allMatches(src)) {
          final target = '$dir/${m.group(1)!.substring(2)}';
          if (!isTracked(target)) broken.add('$f -> ${m.group(1)}');
        }
      }
      expect(broken, isEmpty,
          reason: 'these committed files import files that are NOT committed:\n'
              '  ${broken.join('\n  ')}\n\n'
              'deno test runs against your working tree, so it passes while '
              'HEAD is broken.');
    });

    test('every committed test that reads a repo file reads a tracked one', () {
      // The `ci_release_gate_authority_test` case: a committed test opened an
      // untracked shell script, so it could not even load on a clean checkout.
      final broken = <String>[];
      for (final f in tracked('app/test/*.dart')) {
        final src = File('$repoRoot/$f').readAsStringSync();
        for (final m in RegExp(r"""File\('(\.\./[A-Za-z0-9_./-]+)'\)""")
            .allMatches(src)) {
          final rel = m.group(1)!.substring(3); // strip leading ../
          if (!isTracked(rel) && !Directory('$repoRoot/$rel').existsSync()) {
            broken.add('$f -> ${m.group(1)}');
          }
        }
      }
      expect(broken, isEmpty,
          reason: 'these committed tests read files that are NOT committed:\n'
              '  ${broken.join('\n  ')}');
    });
  });

  group('the gate result describes HEAD, not a working tree', () {
    /// The one divergence class this file cannot detect statically.
    ///
    /// The other checks catch a file being ABSENT from HEAD. They cannot catch
    /// a file being PRESENT but OLDER than the tests asserting against it —
    /// which is exactly how the admin UI break hid: `coupon-admin.test.mjs` was
    /// committed asserting behaviour that only the working tree's pages had, so
    /// the suite read 102/0 locally and 94/7 at HEAD.
    ///
    /// Detecting that statically would mean understanding what each test
    /// asserts, which is not a maintainable check. What IS deterministic is
    /// asking whether the tree the gate is running against equals HEAD. If it
    /// does, "the gate passed" and "HEAD passes" are the same statement; if it
    /// does not, they are two different claims and only one of them was tested.
    ///
    /// Enforced only under `REQUIRE_PRISTINE_TREE=1`, which `ci_gates.sh` sets
    /// in strict/release mode. Failing on every dirty tree would make the suite
    /// unusable during normal development, and a gate people must routinely
    /// ignore is not a gate.
    test('under REQUIRE_PRISTINE_TREE, no tracked file differs from HEAD', () {
      final strict =
          Platform.environment['REQUIRE_PRISTINE_TREE'] == '1';

      final r = Process.runSync(
        'git',
        ['status', '--porcelain', '--untracked-files=no'],
        workingDirectory: repoRoot,
        stdoutEncoding: utf8,
      );
      final dirty = (r.stdout as String)
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();

      if (!strict) {
        // Reported, never asserted, outside strict mode — the number is the
        // useful part: it says how far this run's evidence is from HEAD's.
        // ignore: avoid_print
        print(dirty.isEmpty
            ? 'tree matches HEAD — this gate result describes HEAD'
            : 'NOTE: ${dirty.length} tracked file(s) differ from HEAD; this '
                'gate result describes the WORKING TREE, not HEAD. Re-run with '
                'REQUIRE_PRISTINE_TREE=1 on a clean checkout before treating it '
                'as release evidence.');
        return;
      }

      expect(dirty, isEmpty,
          reason: 'REQUIRE_PRISTINE_TREE=1 but ${dirty.length} tracked file(s) '
              'differ from HEAD:\n  ${dirty.take(20).join('\n  ')}\n\n'
              'A release gate must test the code being released. With a dirty '
              'tree, a pass proves something about your local files and '
              'nothing about the commit.');
    });
  });
}
