import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// CAP-6a — queue v3: owner record, stamping, quotas, unbound claim CAS,
/// legacy v2 migration and the Remove-data barrier (manifest §4.2-§4.5, §4.7).
///
/// Swift cannot run here. The behavioural proof is `ios/RunnerTests/
/// RunnerTests.swift` (the CAP-6 section, needs Xcode and a device/simulator
/// with the App Group + Keychain entitlements); these static checks pin the
/// source properties that make it true so a regression fails in Linux CI. The
/// style follows capture_queue_cap0_contract_test.dart.
void main() {
  final store = File('ios/Runner/SharedCaptureStore.swift').readAsStringSync();
  final storeCopy =
      File('ios/ShareBankMessage/SharedCaptureStore.swift').readAsStringSync();
  final intent = File('ios/BankMessageShortcuts/BankMessageShortcuts.swift')
      .readAsStringSync();
  final appDelegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();
  final share =
      File('ios/ShareBankMessage/ShareViewController.swift').readAsStringSync();
  final xctest = File('ios/RunnerTests/RunnerTests.swift').readAsStringSync();

  /// The text from the `{` after [signature] to its matching `}`.
  String body(String source, String signature) {
    final at = source.indexOf(signature);
    expect(at, greaterThan(-1), reason: '$signature not found');
    final open = source.indexOf('{', at + signature.length);
    var depth = 0;
    for (var i = open; i < source.length; i++) {
      if (source[i] == '{') depth++;
      if (source[i] == '}' && --depth == 0) {
        return source.substring(open, i + 1);
      }
    }
    fail('unbalanced braces after $signature');
  }

  group('store identity', () {
    test('the Runner and Share Extension copies are byte-identical', () {
      expect(storeCopy, store);
    });

    test('queue v3 is an atomic, file-protected file; not flag-gated', () {
      expect(store, contains('"pending_bank_messages_v3.bin"'));
      final save = body(store, 'private static func saveQueue(');
      expect(save, contains('.atomic'), reason: 'temp file + rename');
      expect(save,
          contains('.completeFileProtectionUntilFirstUserAuthentication'));
      // One-way format change: manifest §9 lists P2 as "no flag".
      expect(store, isNot(contains('capture_import_v3')));
      expect(intent, isNot(contains('capture_import_v3')));
    });
  });

  group('owner record and stamping (§4.2)', () {
    test('every owner/queue entry point runs under the queue flock', () {
      for (final sig in const [
        'static func activeOwner()',
        'static func publishActiveOwner(',
        'static func clearActiveOwner(',
        'static func setConsentMirror(',
        'static func authorizeUpload(',
        'static func unboundSummary(',
        'private static func casUnbound(',
        'static func resolveLegacyItems(',
        'static func beginRemoval(',
        'static func removalBarrier()',
        'static func finishRemoval(',
        'static func queueSnapshot()',
      ]) {
        final fn = body(store, sig).trimLeft();
        expect(
          fn.substring(1).trimLeft(),
          anyOf(startsWith('try withQueueLock'),
              startsWith('(try? withQueueLock')),
          reason: '$sig must take the flock before touching the owner record '
              'or the queue (no unlocked fallback)',
        );
      }
    });

    test('the owner record is written only inside publishActiveOwner', () {
      expect(
        RegExp(r'writeKeychain\([^)]*forKey: activeOwnerKC\)')
            .allMatches(store)
            .length,
        1,
      );
      final publish = body(store, 'static func publishActiveOwner(');
      expect(publish, contains('forKey: activeOwnerKC'));
      expect(publish, contains('forKey: lastAdmittedHashKC'));
      expect(publish, contains('QueueError.barrierActive'),
          reason: 'no owner may be published while a removal runs');
    });

    test('intent critical section: barrier, owner read, stamp, quota, save',
        () {
      final enqueue = body(store, 'static func enqueue(');
      final order = [
        'withQueueLock',
        'stampingHook?()',
        'try readBarrier()',
        'loadQueuePruned()',
        'try readActiveOwner()',
        'ownerStateStamped',
        'ownerStateUnbound',
        'try checkQuotas(',
        'try saveQueue(',
      ];
      var last = -1;
      for (final token in order) {
        final at = enqueue.indexOf(token, last + 1);
        expect(at, greaterThan(last), reason: '$token out of order or missing');
        last = at;
      }
      expect(enqueue, contains('throw QueueError.barrierActive'));
      expect(
          enqueue, contains('stamped.ownerHint = try readLastAdmittedHash()'));
      expect(enqueue, contains('stamped.unboundAt = createdAtString'));
      // Keychain unavailable (before first unlock) propagates as a throw, so
      // nothing is persisted and the intent fails visibly.
      expect(enqueue, isNot(contains('try? readActiveOwner')));
      expect(enqueue, isNot(contains('try? readLastAdmittedHash')));
    });

    test('a failed owner-record read throws, never "no owner"', () {
      final read = body(store, 'private static func readActiveOwner()');
      expect(read, contains('case errSecItemNotFound:'));
      expect(read, contains('throw QueueError.keyUnavailable(read.status)'));
    });

    test('a transition clears the hint; a sign-out keeps it', () {
      final clear = body(store, 'static func clearActiveOwner(');
      expect(clear, contains('if clearHint'));
      expect(clear, contains('lastAdmittedHashKC'));
    });

    test('only the ACTIVE owner\'s stamped items are importable', () {
      final importable = body(store, 'private static func importableItems(');
      expect(
          importable, contains('guard let owner = owner else { return [] }'));
      expect(importable, contains(r'$0.ownerState == ownerStateStamped'));
      expect(importable, contains(r'$0.ownerUid == owner.uid'));
      for (final sig in const [
        'static func peekPendingPayloadsJSON()',
        'static func consumePendingPayloadsJSON()',
        'static func consumePendingText()',
        'static func hasPendingMessages()',
      ]) {
        expect(body(store, sig), contains('importableItems('),
            reason: '$sig must be owner-scoped');
      }
    });

    test('the uidHash key is minted only on errSecItemNotFound, no deletes',
        () {
      final key = body(store, 'private static func uidHmacKey()');
      expect(key.indexOf('case errSecItemNotFound:'),
          lessThan(key.indexOf('SecRandomCopyBytes')));
      expect(
          key.indexOf('SecRandomCopyBytes'), lessThan(key.indexOf('default:')));
      expect(key, contains('throw QueueError.keyUnavailable(read.status)'));
      expect(store, contains('HMAC<SHA256>.authenticationCode'));
      // CAP-0 invariant is intact: exactly one place mints the queue key.
      expect('SymmetricKey(size:'.allMatches(store).length, 1);
    });
  });

  group('quotas (§4.5)', () {
    test('the values are exactly the manifest values', () {
      expect(store, contains('static let ownerMaxItems = 500'));
      expect(store, contains('static let ownerMaxBytes = 2 * 1024 * 1024'));
      expect(store, contains('static let unboundMaxItems = 200'));
      expect(store, contains('static let unboundMaxBytes = 512 * 1024'));
      expect(store, contains('static let deviceMaxBytes = 8 * 1024 * 1024'));
      expect(store, contains('static let unboundExpiryDays = 30'));
    });

    test('exhaustion throws before any write and nothing is evicted', () {
      final quota = body(store, 'private static func checkQuotas(');
      expect(quota, contains('throw QueueError.quotaExceeded'));
      expect(quota, contains('ownerMaxItems'));
      expect(quota, contains('unboundMaxItems'));
      expect(quota, contains('deviceMaxBytes'));
      expect(quota, isNot(contains('removeFirst')));
      expect(quota, isNot(contains('removeAll')));
      expect(quota, isNot(contains('saveQueue')));
    });

    test('only UNBOUND items expire by age', () {
      final prune = body(store, 'private static func loadQueuePruned(');
      expect(prune, contains('item.ownerState == ownerStateUnbound'));
      expect(prune, contains('unboundExpiryDays'));
      expect(prune, contains('expiredUnboundCountKey'),
          reason: 'a content-free diagnostics record is kept');
    });

    test('quota refusal reuses the approved copy; no new user-visible text',
        () {
      final copy = body(store, 'var userMessage: String');
      expect('return arabic'.allMatches(copy).length, 3,
          reason: 'only the three approved R9 messages exist');
      expect(
          copy,
          contains(
              'case .storageUnavailable, .quotaFull, .removalInProgress, .ownerChanged:'));
      final enqueue = body(store, 'static func enqueue(');
      expect(enqueue, contains('kind = .quotaFull'));
      expect(enqueue, contains('kind = .removalInProgress'));
    });
  });

  group('unbound claim CAS (§4.3)', () {
    test('every precondition is checked BEFORE the first mutation', () {
      final cas = body(store, 'private static func casUnbound(');
      final apply = cas.indexOf('apply(&queue');
      expect(apply, greaterThan(-1));
      for (final check in const [
        'try readBarrier() == nil',
        'normalizedUID(replicaOwnerUid) == target',
        'normalizedUID(sessionUid) == target',
        'owner.generation == generation',
        'owner.uid == target',
        'queue[\$0].ownerState == ownerStateUnbound',
        'queue[\$0].ownerHint == hash',
      ]) {
        final at = cas.indexOf(check);
        expect(at, greaterThan(-1), reason: '$check missing');
        expect(at, lessThan(apply), reason: '$check must precede the mutation');
      }
      expect(cas.indexOf('return .ownerMismatch'), lessThan(apply));
      expect(cas.indexOf('return .stale'), lessThan(apply));
      expect(cas.indexOf('try saveQueue'), greaterThan(apply));
    });

    test('bound items never upload and never use AI', () {
      final claim = body(store, 'static func claimUnbound(');
      expect(claim, contains('localOnly = true'));
      expect(claim, contains('ownerHint = nil'));
      final auth = body(store, 'static func authorizeUpload(');
      expect(auth, contains('item.localOnly == true'));
      expect(auth, contains('return .localOnly'));
    });

    test('discard uses the same CAS', () {
      expect(
          body(store, 'static func discardUnbound('), contains('casUnbound('));
      expect(body(store, 'static func claimUnbound('), contains('casUnbound('));
    });

    test('a hint is never authority: recovery needs the hint to match', () {
      final summary = body(store, 'static func unboundSummary(');
      expect(summary, contains(r'$0.ownerHint == hash'));
      expect(summary, contains('uidHash(uid)'));
    });
  });

  group('legacy v2 migration (§4.7)', () {
    test('everything becomes unbound with NO hint, nothing is dropped', () {
      final quarantine = body(store, 'private static func quarantinedLegacy(');
      expect(quarantine, contains('ownerState = ownerStateUnbound'));
      expect(quarantine, contains('ownerUid = nil'));
      expect(quarantine, contains('ownerHint = nil'));
      expect(quarantine, contains('originLegacyV2'));
      final migrate = body(store, 'private static func migrateLegacyQueue(');
      expect(migrate, isNot(contains('checkQuotas')),
          reason: 'a legacy item is never evicted');
      expect(migrate, isNot(contains('readLastAdmittedHash')),
          reason: 'no hint is ever derived for a legacy item');
      expect(migrate, contains('migratedKey'));
      expect(migrate, contains('try decodeQueueBlob(blob)'),
          reason: 'an unreadable v2 blob fails closed and is not overwritten');
    });

    test('the v2 blob is kept for the rollback grace (only purge removes it)',
        () {
      final removals =
          RegExp(r'removeObject\(forKey: queueKey\)').allMatches(store);
      expect(removals.length, 1);
      final purge = body(store, 'static func purgeUserOwnedState()');
      expect(purge, contains('removeObject(forKey: queueKey)'));
    });

    test('only Dart\'s receipt/tx verdict removes; fingerprint is review-only',
        () {
      final resolve = body(store, 'static func resolveLegacyItems(');
      expect(resolve, contains('item.origin == originLegacyV2'));
      expect(resolve, contains('consumed.contains'));
      expect(resolve, contains('reviewSuspectedAlreadyImported'));
      expect(resolve, isNot(contains('ownerState = ownerStateStamped')),
          reason: 'resolution never binds an item');
      expect(store, contains('"suspected_already_imported"'));
    });
  });

  group('Remove-data barrier (§4.4)', () {
    test('begin: barrier written first, then the owner is cleared', () {
      final begin = body(store, 'static func beginRemoval(');
      expect(begin.indexOf('barrierFileName'),
          lessThan(begin.indexOf('removeKeychain(forKey: activeOwnerKC)')));
      expect(begin, contains('throw QueueError.barrierActive'));
      expect(begin, contains('if let existing = try readBarrier()'),
          reason: 'resumable and idempotent after a crash');
    });

    test('sweep: owner, hint, barrier time and nonce; the barrier clears LAST',
        () {
      final finish = body(store, 'static func finishRemoval(');
      for (final predicate in const [
        'item.ownerUid == target',
        'item.ownerHint == hash',
        'item.barrierNonce == barrier.nonce',
        'created >= started',
      ]) {
        expect(finish, contains(predicate));
      }
      final sweep = finish.indexOf('queue.removeAll');
      final save = finish.indexOf('try saveQueue(queue');
      final hint = finish.indexOf('removeKeychain(forKey: lastAdmittedHashKC)');
      final mirror = finish.indexOf('mirror.removeValue(forKey: hash)');
      final clear = finish.indexOf('removeItem(at: url)');
      expect(sweep, lessThan(save));
      expect(save, lessThan(hint));
      expect(hint, lessThan(clear));
      expect(mirror, lessThan(clear));
      expect(clear, greaterThan(0));
      expect(finish.substring(clear + 1), isNot(contains('removeItem(')),
          reason: 'clearing the barrier is the last mutation');
    });

    test('an unreadable barrier fails closed', () {
      final read = body(store, 'private static func readBarrier()');
      expect(read, contains('throw QueueError.unreadable'));
    });
  });

  group('call sites', () {
    test('the App Intent re-checks the owner before any upload', () {
      final auth = intent.indexOf('SharedCaptureStore.authorizeUpload(');
      final upload = intent.indexOf('let attempt = await processBackend(');
      expect(auth, greaterThan(-1));
      expect(auth, lessThan(upload));
      final gate = intent.substring(auth, upload);
      expect(gate, contains('case .localOnly:'));
      expect(gate, contains('case .waiting:'));
      expect(gate, isNot(contains('processBackend')),
          reason: 'zero egress on the local-only and waiting branches');
      // The pre-network durability contract (H-19) still holds.
      expect(intent.indexOf('status: .pendingSend'), lessThan(auth));
    });

    test('v2 upload carries owner_uid only when the capability is mirrored on',
        () {
      expect(intent, contains('if config.captureContractV2, let ownerUid'));
      expect(intent, contains('body["schema_version"] = 2'));
      expect(intent, contains('body["owner_uid"] = ownerUid'));
      expect(store, contains('var captureContractV2: Bool = false'));
      expect(store, contains('captureContractV2: Bool = false'));
    });

    test('the method channel exposes the bridge contract with typed codes', () {
      for (final method in const [
        'publishCaptureOwner',
        'clearCaptureOwner',
        'getCaptureOwner',
        'setCaptureConsentMirror',
        'unboundCaptureSummary',
        'claimUnboundCaptures',
        'discardUnboundCaptures',
        'resolveLegacyCaptureItems',
        'beginCaptureRemoval',
        'getCaptureRemovalBarrier',
        'finishCaptureRemoval',
      ]) {
        expect(appDelegate, contains('"$method"'));
      }
      for (final code in const [
        '"quota_exceeded"',
        '"removal_in_progress"',
        '"owner_changed"',
        '"queue_unavailable"',
      ]) {
        expect(appDelegate, contains(code));
      }
      expect(appDelegate,
          contains('requireOwnerUid: args["ownerUid"] as? String'));
    });

    test('the Share Extension still shows only the approved copy', () {
      expect(share, contains('NSLocalizedDescriptionKey: kind.userMessage'));
      expect(share, isNot(contains('quota')));
    });
  });

  test('the XCTest cases for the CAP-6 gates exist', () {
    for (final name in const [
      'testStampingOwnerUnboundHintAndTransition',
      'testNonActiveOwnerItemWaitsAndResumes',
      'testUploadAuthorizationOwnerMismatchAndConsentMirror',
      'testOwnerRecordUnavailablePersistsNothing',
      'testFlockHeldDuringStamping',
      'testQuotaValuesAreTheManifestValues',
      'testUnboundCountQuotaFailsVisiblyWithoutEviction',
      'testOwnerCountQuotaFailsVisiblyWithoutEviction',
      'testUnboundAndOwnerByteQuotas',
      'testDeviceByteQuota',
      'testUnboundExpiresAfter30DaysStampedDoesNot',
      'testV2MigrationQuarantinesEverythingWithoutHint',
      'testUnboundHintAndClaimCAS',
      'testDiscardUsesTheSameCAS',
      'testClaimRaceTwoClaimersExactlyOneWins',
      'testRemovalBarrierBlocksIntentAndSweepsEverythingOfA',
      'testRemovalClearsLastAdmittedHintWhenItIsA',
      'testReEnqueueRequiresOriginalOwner',
    ]) {
      expect(xctest, contains('func $name('));
    }
  });
}
