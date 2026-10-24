import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/database_access_broker.dart';
import 'package:path/path.dart' as p;

// Astra R45 R5 — legacy/unregistered-holder evidence is gathered WITHOUT
// creating anything and distinguishes VERIFIED ABSENCE from a failed or
// ambiguous lookup. `FileSystemEntity.typeSync` reports `notFound` for absence
// AND for other lookup errors, so a `notFound` alone is never evidence.

void main() {
  late Directory root;
  late String replica;
  late String leaseDir;
  late String intent;

  setUp(() {
    root = Directory.systemTemp.createTempSync('legacy_evidence_');
    replica = p.join(root.path, 'replica');
    Directory(replica).createSync();
    leaseDir = p.join(replica, 'db_leases');
    intent = p.join(replica, 'qirsh.sqlite.maint');
  });

  tearDown(() {
    // Restore permissions so the tree can be deleted.
    try {
      Process.runSync('chmod', ['-R', 'u+rwx', root.path]);
    } catch (_) {}
    root.deleteSync(recursive: true);
  });

  /// Every path under the root with its type and mode; unreadable directories
  /// are recorded as such (never entered, never changed).
  List<String> tree() {
    final out = <String>[];
    void walk(String dir) {
      try {
        for (final e in Directory(dir).listSync(followLinks: false)) {
          final stat = FileStat.statSync(e.path);
          out.add(
              '${e.path}|${FileSystemEntity.typeSync(e.path, followLinks: false)}|${stat.mode}');
          if (FileSystemEntity.typeSync(e.path, followLinks: false) ==
              FileSystemEntityType.directory) {
            walk(e.path);
          }
        }
      } on FileSystemException {
        out.add('$dir|unreadable');
      }
    }

    walk(root.path);
    return out..sort();
  }

  LegacyHolderEvidence inspect() => LegacyHolderEvidence.inspect(
      replicaDirectory: replica, leaseDir: leaseDir, intentPath: intent);

  void expectDeniedAndNothingCreated(String reason) {
    final before = tree();
    final evidence = inspect();
    expect(evidence.isClear, isFalse, reason: reason);
    expect(tree(), before, reason: 'inspection created or changed something');
  }

  group('verified absence is the only clear evidence', () {
    test('no lease directory and no intent in a readable replica directory',
        () {
      final before = tree();
      expect(inspect().isClear, isTrue);
      expect(tree(), before, reason: 'zero created files');
    });

    test('an existing empty lease directory is clear and is not modified', () {
      Directory(leaseDir).createSync();
      final before = tree();
      expect(inspect().isClear, isTrue);
      expect(tree(), before);
    });
  });

  group('lookup failure and ambiguity deny', () {
    test('an inaccessible replica directory (lookup fails, not absence)', () {
      Process.runSync('chmod', ['000', replica]);
      expectDeniedAndNothingCreated('listing the replica directory fails');
    });

    test('an inaccessible lease directory', () {
      Directory(leaseDir).createSync();
      Process.runSync('chmod', ['000', leaseDir]);
      expectDeniedAndNothingCreated('lease directory cannot be read');
    });

    test('a dangling symlink where the lease directory belongs', () {
      Link(leaseDir).createSync(p.join(root.path, 'nowhere'));
      expectDeniedAndNothingCreated('dangling link is not absence');
    });

    test('a symlink to a real empty directory is an unexpected link', () {
      final target = Directory(p.join(root.path, 'elsewhere'))..createSync();
      Link(leaseDir).createSync(target.path);
      expectDeniedAndNothingCreated('unexpected link type');
    });

    test('a symlink loop where the maintenance intent belongs', () {
      Link(intent).createSync(intent);
      expectDeniedAndNothingCreated('ELOOP lookup error is not absence');
    });

    test('a dangling symlink where the maintenance intent belongs', () {
      Link(intent).createSync(p.join(root.path, 'nowhere'));
      expectDeniedAndNothingCreated('an intent-named link is not absence');
    });

    test('the replica directory itself is a link', () {
      final real = Directory(p.join(root.path, 'real'))..createSync();
      final linked = p.join(root.path, 'linked');
      Link(linked).createSync(real.path);
      final before = tree();
      final evidence = LegacyHolderEvidence.inspect(
          replicaDirectory: linked,
          leaseDir: p.join(linked, 'db_leases'),
          intentPath: p.join(linked, 'qirsh.sqlite.maint'));
      expect(evidence.isClear, isFalse);
      expect(tree(), before);
    });

    test('a missing replica directory is not evidence of no holder', () {
      Directory(replica).deleteSync();
      expect(inspect().isClear, isFalse);
      expect(Directory(replica).existsSync(), isFalse);
    });

    test('a file where the lease directory belongs', () {
      File(leaseDir).writeAsStringSync('x');
      expectDeniedAndNothingCreated('wrong path type');
    });

    test('a lease directory or intent outside the inspected replica directory',
        () {
      final other = p.join(root.path, 'other_leases');
      final before = tree();
      expect(
          LegacyHolderEvidence.inspect(
                  replicaDirectory: replica,
                  leaseDir: other,
                  intentPath: intent)
              .isClear,
          isFalse);
      expect(tree(), before);
    });
  });

  group('records and intents deny', () {
    test('a live lease record', () {
      Directory(leaseDir).createSync();
      File(p.join(leaseDir, '1_0_a.lease')).writeAsStringSync('t\n1\ni');
      expectDeniedAndNothingCreated('live lease');
    });

    test('a half-published (temporary) record', () {
      Directory(leaseDir).createSync();
      File(p.join(leaseDir, '1_0_a.lease.tok.tmp')).writeAsStringSync('');
      expectDeniedAndNothingCreated('half-published record');
    });

    test('a maintenance intent', () {
      File(intent).writeAsStringSync('t\n1\ni');
      expectDeniedAndNothingCreated('maintenance intent');
    });
  });
}
