import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/creation_policy.dart';
import 'package:money_companion/data/db/database_lease.dart';
import 'package:money_companion/data/db/replica_location.dart';
import 'package:money_companion/data/db/replica_store.dart';
import 'package:path/path.dart' as p;

import '../../core/session/recording_secure_storage.dart';

// F2 round 2 — storage exclusion (R2-3) and rebootstrap-swap exclusion (R2-4).
//
// Real SQLCipher files in a temp directory; the recording secure storage notes
// every write/delete ATTEMPT in order and can hold one operation, so a swap can
// be paused at any internal mutation boundary and a key write delayed, while
// Remove data is accepted. Nothing sleeps for correctness: real-time delays are
// used only to give an operation that SHOULD be blocked the chance to (wrongly)
// complete.

const _uid = 'uid-aaaa';

Future<void> settle() =>
    Future<void>.delayed(const Duration(milliseconds: 200));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;
  late RecordingSecureStorage rec;

  setUp(() {
    support = Directory.systemTemp.createTempSync('replica_exclusion_');
    rec = RecordingSecureStorage().install();
  });
  tearDown(() {
    if (support.existsSync()) support.deleteSync(recursive: true);
  });

  ReplicaStore strict({Future<void> Function(String)? step}) => ReplicaStore(
        appSupportDirectory: support.path,
        debugAfterAdoptionStep: step,
      );

  Directory dirOf(String hash, [String suffix = '']) =>
      Directory(p.join(support.path, 'replicas', '$hash$suffix'));

  group('R2-3 existing-only opens create nothing', () {
    test('R2-3 even when the existence pre-check is stale (the file vanished '
        'after it), an existing-only open makes no directory, file or key',
        () async {
      final loc = ReplicaLocation(
        directory: p.join(support.path, 'replicas', 'ghost'),
        dbFileName: 'qirsh.sqlite',
        keyName: 'qirsh.db_key.ghost',
      );
      rec.data[loc.keyName] = 'seeded-key-value';

      await expectLater(
        AppDatabase.open(
          location: loc,
          creation: const CreationPolicy.denied(),
          databaseFileExists: () async => true, // the check passed, then...
        ),
        throwsA(anything),
      );

      expect(Directory(loc.directory).existsSync(), isFalse,
          reason: 'no parent directory');
      expect(File(loc.dbPath).existsSync(), isFalse, reason: 'no database file');
      expect(rec.attempts.where((a) => a.startsWith('write:')), isEmpty);
    });

    test('R2-3 the same with the replica directory present but the file gone',
        () async {
      final loc = ReplicaLocation(
        directory: p.join(support.path, 'replicas', 'ghost'),
        dbFileName: 'qirsh.sqlite',
        keyName: 'qirsh.db_key.ghost',
      );
      Directory(loc.directory).createSync(recursive: true);
      rec.data[loc.keyName] = 'seeded-key-value';

      await expectLater(
        AppDatabase.open(
          location: loc,
          creation: const CreationPolicy.denied(),
          databaseFileExists: () async => true,
        ),
        throwsA(anything),
      );

      expect(File(loc.dbPath).existsSync(), isFalse);
      expect(Directory(loc.directory).listSync(), isEmpty,
          reason: 'no sidecar, no WAL, no journal');
    });
  });

  group('R2-3 removal takes the exclusive lease', () {
    Future<(ReplicaStore, ReplicaLocation, DatabaseLeaseManager)> replica() async {
      final s = strict();
      await s.openReplica(_uid,
          authority: const AdmissionAuthority.forTest(_uid));
      final loc = await s.locationFor(_uid);
      final mgr = DatabaseLeaseManager(
        leaseDir: loc.leaseDir,
        intentPath: loc.maintPath,
        settleWindow: const Duration(milliseconds: 5),
        pollStep: const Duration(milliseconds: 5),
      );
      return (s, loc, mgr);
    }

    test('R2-3 removal waits for a secondary connection\'s shared lease; while '
        'it holds the maintenance intent no secondary is admitted; after the '
        'directory is gone a late secondary recreates nothing', () async {
      final (s, loc, mgr) = await replica();
      final secondary = await mgr.acquireShared(); // a background isolate

      var removed = false;
      final removal = s.remove(_uid).then((_) => removed = true);
      await settle();
      expect(removed, isFalse,
          reason: 'the secondary must drain before anything is deleted');
      expect(Directory(loc.directory).existsSync(), isTrue);
      expect(File(loc.dbPath).existsSync(), isTrue);
      await expectLater(mgr.acquireShared(),
          throwsA(isA<DatabaseLeaseUnavailable>()),
          reason: 'exclusion is published while it drains');

      await secondary.release();
      await removal;
      expect(Directory(loc.directory).existsSync(), isFalse);

      // Exclusion survives the directory removal: nothing can be admitted, and
      // an attempt leaves no directory behind.
      await expectLater(
          mgr.acquireShared(), throwsA(isA<DatabaseLeaseUnavailable>()));
      expect(Directory(loc.directory).existsSync(), isFalse,
          reason: 'a late secondary must not recreate the replica directory');
    });
  });

  group('R2-4 a rebootstrap swap shares the removal exclusion', () {
    String keyOf(String hash, [String suffix = '']) =>
        'qirsh.db_key.$hash$suffix';

    /// A replica with a rebootstrap staging copy ready to swap.
    Future<ReplicaStore> readyToSwap({
      Future<void> Function(String)? step,
    }) async {
      final s = strict(step: step);
      await s.openReplica(_uid,
          authority: const AdmissionAuthority.forTest(_uid));
      await s.beginRebootstrap(_uid, 'reset');
      await s.openStaging(_uid,
          authority: const AdmissionAuthority.forTest(_uid));
      return s;
    }

    Future<void> expectNothingSurvives(ReplicaStore s, String hash,
        {required int fromAttempt}) async {
      for (final suffix in ['', '.rb', '.old']) {
        expect(dirOf(hash, suffix).existsSync(), isFalse,
            reason: 'directory <hash>$suffix');
        expect(rec.data.containsKey(keyOf(hash, suffix)), isFalse,
            reason: 'key <hash>$suffix');
      }
      expect(Directory(p.join(support.path, 'replicas'))
          .listSync()
          .map((e) => p.basename(e.path))
          .where((n) => n.startsWith('_removing') || n.startsWith(hash)),
          isEmpty);
      expect((await s.list()).any((e) => e.uidHash == hash), isFalse,
          reason: 'registry entry');
      // No key write may land after that key's deletion began.
      for (final suffix in ['', '.rb', '.old']) {
        final k = keyOf(hash, suffix);
        final attempts = rec.attempts.skip(fromAttempt).toList();
        final lastDelete = attempts.lastIndexOf('delete:$k');
        final lastWrite =
            attempts.lastIndexWhere((a) => a.startsWith('write:$k='));
        if (lastDelete >= 0 && lastWrite >= 0) {
          expect(lastWrite, lessThan(lastDelete),
              reason: 'a write of $k landed after the removal deleted it');
        }
      }
    }

    Future<void> removeWhileSwapPaused({
      required Future<ReplicaStore> Function(Hold hold) build,
      required Hold hold,
    }) async {
      final s = await build(hold);
      final hash = await s.uidHash(_uid);
      final from = rec.attempts.length;
      final swap = s.swapStaging(_uid).then<Object?>((_) => null,
          onError: (Object e) => e);
      await hold.reached.future;

      var removed = false;
      final removal = s.remove(_uid).then((_) => removed = true);
      await settle();
      expect(removed, isFalse,
          reason: 'removal waits for the paused swap instead of racing it');

      hold.release.complete();
      final swapOutcome = await swap;
      await removal;

      expect(swapOutcome, isA<StaleAdmissionException>(),
          reason: 'the swap was revoked at its next mutation boundary');
      await expectNothingSurvives(s, hash, fromAttempt: from);
    }

    for (final step in kSwapSteps) {
      test('R2-4 removal while the swap is paused after "$step": no .old, no '
          '.rb, no live copy, no key survives and no delayed swap restores '
          'anything', () async {
        final hold = Hold();
        await removeWhileSwapPaused(
          hold: hold,
          build: (h) => readyToSwap(step: (s) async {
            if (s == step && !h.used) {
              h.used = true;
              h.reached.complete();
              await h.release.future;
            }
          }),
        );
      });
    }

    for (final (label, suffix) in [
      ('the retired-key copy (.old)', '.old'),
      ('the live key (fresh key promoted)', ''),
    ]) {
      test('R2-4 a DELAYED key write of $label cannot land after the removal',
          () async {
        late Hold hold;
        await removeWhileSwapPaused(
          hold: hold = Hold(),
          build: (_) async {
            final s = await readyToSwap();
            final hash = await s.uidHash(_uid);
            final target = keyOf(hash, suffix);
            // Hold the swap's own write of that key (not the earlier creation).
            final real = rec.holdOnce((op, key) => op == 'write' && key == target);
            real.reached.future.then((_) => hold.reached.complete());
            hold.release.future.then((_) => real.release.complete());
            return s;
          },
        );
      });
    }

    test('R2-4 removal while the swap is paused at its very first registry '
        'mutation', () async {
      late Hold hold;
      await removeWhileSwapPaused(
        hold: hold = Hold(),
        build: (_) async {
          final s = await readyToSwap();
          final real = rec.holdOnce(
              (op, key) => op == 'write' && key == ReplicaStore.registryKey);
          real.reached.future.then((_) => hold.reached.complete());
          hold.release.future.then((_) => real.release.complete());
          return s;
        },
      );
    });

    test('R2-4 an unrelated replica is untouched by a removal that revokes a '
        'swap', () async {
      final other = strict();
      await other.openReplica('uid-other',
          authority: const AdmissionAuthority.forTest('uid-other'));
      await other.closeAll();
      final hOther = await other.uidHash('uid-other');
      final keyOther = rec.data[keyOf(hOther)];
      final entryOther =
          (await other.list()).firstWhere((e) => e.uidHash == hOther).toJson();

      final hold = Hold();
      await removeWhileSwapPaused(
        hold: hold,
        build: (h) => readyToSwap(step: (s) async {
          if (s == 'swap:afterOldMoved' && !h.used) {
            h.used = true;
            h.reached.complete();
            await h.release.future;
          }
        }),
      );
      expect(dirOf(hOther).existsSync(), isTrue);
      expect(rec.data[keyOf(hOther)], keyOther);
      expect((await other.list()).firstWhere((e) => e.uidHash == hOther).toJson(),
          entryOther);
    });
  });

  group('R2-5 an authority revoked while an open is in flight', () {
    test('R2-5 a handle opened under an authority revoked meanwhile is closed '
        'and refused, not returned', () async {
      final s = strict();
      var live = true;
      final authority = AdmissionAuthority(_uid, () => live, canCreate: true);
      final hold = rec.holdOnce(
          (op, key) => op == 'write' && key == ReplicaStore.registryKey);
      Object? outcome;
      final opening = s
          .openReplica(_uid, authority: authority)
          .then<void>((_) {}, onError: (Object e) => outcome = e);
      await hold.reached.future;
      live = false; // Remove data accepted while the open is in flight
      hold.release.complete();
      await opening;

      expect(outcome, isA<StaleAdmissionException>(),
          reason: 'a revoked authority must not receive a usable handle');
    });
  });
}
