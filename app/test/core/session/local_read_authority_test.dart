import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/core/session/local_read_authority.dart';
import 'package:money_companion/data/db/database_key_store.dart';

import 'recording_secure_storage.dart';

// Offline local read — the typed grant/deny codec and the serialized durable
// protocol (core unit). Pure protocol tests over an injected store: no SQLite,
// no AppSession. The real read-only database path is local_read_replica_test.dart.

const _uid = 'uid-a';
const _other = 'uid-b';
const _replica = 'replica-a';

/// A durable store with deterministic faults. `onWrite` runs after the write was
/// DISPATCHED and before it LANDS, so a test can interleave exactly there.
class _Store implements LocalReadDurableStore {
  String? value;
  final List<String> attempts = [];
  final List<String> landed = [];
  bool failWrites = false;
  bool dropWrites = false;
  bool failReads = false;
  Future<void> Function(LocalReadGrantRecord record)? onWrite;
  Future<void> Function()? onRead;

  LocalReadGrantRecord? get record => LocalReadGrantRecord.tryDecode(value);

  @override
  Future<String?> read() async {
    await onRead?.call();
    if (failReads) throw StateError('read');
    return value;
  }

  @override
  Future<void> write(String v) async {
    attempts.add(v);
    await onWrite?.call(LocalReadGrantRecord.tryDecode(v)!);
    if (failWrites) throw StateError('write');
    if (dropWrites) return;
    value = v;
    landed.add(v);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Store store;
  late int nonce;
  late LocalReadAuthority authority;

  LocalReadAuthority make([_Store? s]) => LocalReadAuthority(
        store: s ?? store,
        newOperationId: () => 'op-${++nonce}',
      );

  LocalReadIssueProof proof({String uid = _uid, bool Function()? live}) =>
      LocalReadIssueProof(uid: uid, isCurrent: live ?? () => true);

  Future<LocalReadCapability> grant({String uid = _uid}) async {
    final issue = await authority.beginIssue(uid: uid, replicaId: _replica);
    return authority.commit(issue, proof: proof(uid: uid));
  }

  setUp(() {
    store = _Store();
    nonce = 0;
    authority = make();
  });

  group('codec', () {
    test('round-trips exactly the five documented fields', () {
      const record = LocalReadGrantRecord(
        state: LocalReadGrantState.committed,
        operationId: 'op',
        uid: _uid,
        replicaId: _replica,
      );
      expect(
          record.encode(),
          '{"version":1,"state":"committed","operationId":"op",'
          '"uid":"uid-a","replicaId":"replica-a"}');
      final back = LocalReadGrantRecord.tryDecode(record.encode())!;
      expect(back.state, LocalReadGrantState.committed);
      expect(back.operationId, 'op');
      expect(back.uid, _uid);
      expect(back.replicaId, _replica);
    });

    test('anything missing, malformed, extra or of another version denies', () {
      const good = '{"version":1,"state":"committed","operationId":"op",'
          '"uid":"u","replicaId":"r"}';
      expect(LocalReadGrantRecord.tryDecode(good), isNotNull);
      for (final bad in <String?>[
        null,
        '',
        'not json',
        '[]',
        '{}',
        good.replaceFirst('"version":1', '"version":2'),
        good.replaceFirst('"version":1', '"version":"1"'),
        good.replaceFirst('committed', 'granted'),
        good.replaceFirst('"op"', '""'),
        good.replaceFirst('"uid":"u"', '"uid":""'),
        good.replaceFirst('"replicaId":"r"', '"replicaId":""'),
        good.replaceFirst('"uid":"u"', '"uid":7'),
        good.replaceFirst('}', ',"token":"x"}'),
        good.replaceFirst('"replicaId":"r"', '"rep":"r"'),
      ]) {
        expect(LocalReadGrantRecord.tryDecode(bad), isNull, reason: '$bad');
      }
    });

    test('only a blocked record may omit the replica id', () {
      const blocked = '{"version":1,"state":"blocked","operationId":"op",'
          '"uid":"u","replicaId":""}';
      expect(LocalReadGrantRecord.tryDecode(blocked), isNotNull);
      expect(
          LocalReadGrantRecord.tryDecode(
              blocked.replaceFirst('blocked', 'preparing')),
          isNull);
    });

    test('only committed grants; the record carries no credential material',
        () {
      for (final s in LocalReadGrantState.values) {
        final json = LocalReadGrantRecord(
                state: s, operationId: 'o', uid: 'u', replicaId: 'r')
            .encode();
        expect(json, isNot(contains('token')));
        expect(json, isNot(contains('key')));
        expect(json, isNot(contains('password')));
      }
    });
  });

  group('secure storage key', () {
    test('is not a qirsh.* secret, so a session wipe removes it', () async {
      expect(SecureLocalReadStore.storageKey.startsWith(kReplicaSecretPrefix),
          isFalse);
      // The wipe VERIFIES against storage (it re-reads what survived and
      // retries it), so the fixture must behave like storage: a delete removes
      // the entry. The contract is the end state, not a number of delete calls.
      final storage = <String, String>{
        SecureLocalReadStore.storageKey: 'x',
        'qirsh.db_key.h': 'k',
        'qirsh.device_salt': 's',
        'money_companion.db_key': 'legacy',
      };
      final protectedBefore = Map<String, String>.of(storage)
        ..remove(SecureLocalReadStore.storageKey);
      final calls = <String>[];
      final result = await wipeSecureStoragePreservingDatabaseKey(
        readAll: () async => Map<String, String>.of(storage),
        delete: (k) async {
          calls.add(k);
          storage.remove(k);
        },
      );
      expect(storage.containsKey(SecureLocalReadStore.storageKey), isFalse);
      expect(storage, protectedBefore,
          reason: 'database keys, salt and the legacy key are all preserved');
      expect(calls.toSet(), {SecureLocalReadStore.storageKey},
          reason: 'only the grant was ever targeted for deletion');
      expect(result.isComplete, isTrue);
      expect(result.deleted, [SecureLocalReadStore.storageKey]);
    });

    test(
        'a grant delete that fails once is retried: duplicates are calls, '
        'not extra deletions', () async {
      final storage = <String, String>{
        SecureLocalReadStore.storageKey: 'x',
        'qirsh.db_key.h': 'k',
      };
      final calls = <String>[];
      var failFirst = true;
      final result = await wipeSecureStoragePreservingDatabaseKey(
        readAll: () async => Map<String, String>.of(storage),
        delete: (k) async {
          calls.add(k);
          if (failFirst) {
            failFirst = false;
            throw StateError('transient');
          }
          storage.remove(k);
        },
      );
      expect(
          calls,
          [
            SecureLocalReadStore.storageKey,
            SecureLocalReadStore.storageKey,
          ],
          reason: 'the survivor is swept again after verification');
      expect(storage.keys, ['qirsh.db_key.h']);
      expect(result.isComplete, isTrue);
      expect(result.deleted, [SecureLocalReadStore.storageKey],
          reason: 'reported once, as the single entry it is');
    });

    test('SecureLocalReadStore writes and reads back through secure storage',
        () async {
      final rec = RecordingSecureStorage().install();
      final secure = SecureLocalReadStore();
      expect(await secure.read(), isNull);
      await secure.write('v');
      expect(await secure.read(), 'v');
      expect(rec.writes, ['${SecureLocalReadStore.storageKey}=v']);
    });
  });

  group('issue', () {
    test('preparing is durable before commit; only commit grants', () async {
      final issue = await authority.beginIssue(uid: _uid, replicaId: _replica);
      expect(store.record!.state, LocalReadGrantState.preparing);
      expect(store.record!.operationId, issue.operationId);

      final capability = await authority.commit(issue, proof: proof());
      expect(store.record!.state, LocalReadGrantState.committed);
      expect(store.record!.operationId, issue.operationId);
      expect(capability.isCurrent, isTrue);
      expect(capability.uid, _uid);
      expect(capability.replicaId, _replica);
      expect(store.landed, hasLength(2), reason: 'preparing, then committed');
      // A capability is not the cloud admission authority.
      expect(capability, isNot(isA<AdmissionAuthority>()));
    });

    test('a commit whose lifecycle proof is not live writes nothing', () async {
      final issue = await authority.beginIssue(uid: _uid, replicaId: _replica);
      store.attempts.clear();
      await expectLater(
        authority.commit(issue, proof: proof(live: () => false)),
        throwsA(isA<LocalReadGrantException>()),
      );
      expect(store.attempts, isEmpty);
      expect(store.record!.state, LocalReadGrantState.preparing);

      await expectLater(
        authority.commit(issue, proof: proof(uid: _other)),
        throwsA(isA<LocalReadGrantException>()),
      );
      expect(store.attempts, isEmpty, reason: 'proof of another uid');
    });

    test('the lifecycle lapsing while the commit lands blocks the operation',
        () async {
      final issue = await authority.beginIssue(uid: _uid, replicaId: _replica);
      var live = true;
      store.onWrite = (r) async {
        if (r.state == LocalReadGrantState.committed) live = false;
      };
      await expectLater(
        authority.commit(issue, proof: proof(live: () => live)),
        throwsA(isA<LocalReadGrantException>()),
      );
      expect(store.record!.state, LocalReadGrantState.blocked);
      expect(store.record!.operationId, issue.operationId);
    });

    test('a commit that cannot be read back exposes no grant and denies',
        () async {
      final issue = await authority.beginIssue(uid: _uid, replicaId: _replica);
      store.dropWrites = true; // writes "succeed" but never land
      await expectLater(authority.commit(issue, proof: proof()),
          throwsA(isA<LocalReadGrantException>()));
      store.dropWrites = false;
      expect(store.record!.state, LocalReadGrantState.preparing);
    });

    test('a failed commit write leaves preparing and attempts blocked',
        () async {
      final issue = await authority.beginIssue(uid: _uid, replicaId: _replica);
      store.failWrites = true;
      await expectLater(authority.commit(issue, proof: proof()),
          throwsA(isA<LocalReadGrantException>()));
      expect(store.record!.state, LocalReadGrantState.preparing,
          reason: 'nothing else landed: still denies after a restart');
      expect(authority.isDenialPending, isTrue,
          reason: 'the denial could not be confirmed');
    });

    test('a failed preparing write abandons the issue', () async {
      store.failWrites = true;
      await expectLater(authority.beginIssue(uid: _uid, replicaId: _replica),
          throwsA(isA<LocalReadGrantException>()));
      expect(store.value, isNull);
    });

    test('a crash leaves the durable state at preparing, which denies',
        () async {
      await authority.beginIssue(uid: _uid, replicaId: _replica);
      // The process dies here: only what landed in storage survives.
      expect(LocalReadGrantRecord.tryDecode(store.value)!.state,
          LocalReadGrantState.preparing);
      expect(make().isDenialPending, isFalse);
    });
  });

  group('serialization', () {
    test(
        'a revoke while the commit write is dispatched waits for it, then '
        'lands blocked: nothing resurrects', () async {
      final issue = await authority.beginIssue(uid: _uid, replicaId: _replica);
      final dispatched = Completer<void>();
      final release = Completer<void>();
      store.onWrite = (r) async {
        if (r.state == LocalReadGrantState.committed) {
          dispatched.complete();
          await release.future;
        }
      };
      final commit = authority.commit(issue, proof: proof());
      final commitResult =
          expectLater(commit, throwsA(isA<LocalReadGrantException>()));
      await dispatched.future;

      final revocation = authority.revoke(uid: _uid);
      // Synchronous in-memory effect, before anything lands.
      expect(authority.isDenialPending, isTrue);
      expect(store.record!.state, LocalReadGrantState.preparing);

      release.complete();
      await commitResult;
      expect(await revocation, LocalReadRevocation.denied);
      expect(store.record!.state, LocalReadGrantState.blocked);
      expect(
          store.landed.map(LocalReadGrantRecord.tryDecode).map((r) => r!.state),
          [
            LocalReadGrantState.preparing,
            LocalReadGrantState.committed,
            LocalReadGrantState.blocked,
          ],
          reason:
              'the dispatched grant write finished first, deny landed last');
      expect(authority.isDenialPending, isFalse);
    });

    test('a revoke before the commit write dispatches means it never writes',
        () async {
      final issue = await authority.beginIssue(uid: _uid, replicaId: _replica);
      store.attempts.clear();
      final commit = authority.commit(issue, proof: proof());
      final commitResult =
          expectLater(commit, throwsA(isA<LocalReadGrantException>()));
      final revocation = authority.revoke(uid: _uid);
      await commitResult;
      expect(await revocation, LocalReadRevocation.denied);
      expect(store.attempts, isEmpty,
          reason: 'no committed write was ever dispatched, and the stored '
              'preparing record already denies');
      expect(store.record!.state, LocalReadGrantState.preparing);
    });

    test('a superseded operation cannot commit over a newer one', () async {
      final first = await authority.beginIssue(uid: _uid, replicaId: _replica);
      final second = await authority.beginIssue(uid: _uid, replicaId: 'r2');
      await expectLater(authority.commit(first, proof: proof()),
          throwsA(isA<LocalReadGrantException>()));
      expect(store.record!.operationId, second.operationId);
      expect(store.record!.state, LocalReadGrantState.preparing);

      final capability = await authority.commit(second, proof: proof());
      expect(capability.operationId, second.operationId);
      expect(store.record!.state, LocalReadGrantState.committed);
    });

    test('issuing a replacement revokes the old capability at once', () async {
      final old = await grant();
      expect(old.isCurrent, isTrue);
      final replacement =
          await authority.beginIssue(uid: _uid, replicaId: _replica);
      expect(old.isCurrent, isFalse);
      expect(store.record!.state, LocalReadGrantState.preparing,
          reason: 'old proof unusable even durably');
      await authority.commit(replacement, proof: proof());
    });

    test('a serial grant/revoke race cannot resurrect after a confirmed deny',
        () async {
      final capability = await grant();
      expect(await authority.revoke(uid: _uid), LocalReadRevocation.denied);
      expect(capability.isCurrent, isFalse);
      expect(() => capability.requireCurrent(),
          throwsA(isA<StaleLocalReadException>()));

      final stale = make();
      await expectLater(
        stale.commit(
          (await stale.beginIssue(uid: _uid, replicaId: _replica)),
          proof: proof(live: () => false),
        ),
        throwsA(isA<LocalReadGrantException>()),
      );
      expect(store.record!.state, isNot(LocalReadGrantState.committed));
    });
  });

  test('lifecycle ending during the final exposure check denies the grant',
      () async {
    final issue = await authority.beginIssue(uid: _uid, replicaId: _replica);
    var current = true;
    var checks = 0;
    await expectLater(
      authority.commit(issue, proof: proof(live: () {
        // The fourth predicate call is the final check after lane settlement.
        // A microtask queued by the third check runs after synchronous Future
        // forwarding has already exposed the capability, so use this exact
        // synchronous boundary rather than claiming that microtask came first.
        if (++checks == 4) current = false;
        return current;
      })),
      throwsA(isA<LocalReadGrantException>()
          .having((e) => e.reason, 'reason', LocalReadGrantFailure.notLive)),
    );
    expect(checks, 4);
    expect(store.record!.state, LocalReadGrantState.blocked);
  });

  test('cross-owner denial during final exposure predicate denies B', () async {
    final issue = await authority.beginIssue(uid: _other, replicaId: _replica);
    final denialStarted = Completer<void>();
    final release = Completer<void>();
    Future<LocalReadRevocation>? denial;
    var checks = 0;
    store.onRead = () async {
      if (authority.isDenialPending && !denialStarted.isCompleted) {
        denialStarted.complete();
        await release.future;
      }
    };
    final commit = expectLater(
      authority.commit(issue,
          proof: proof(
              uid: _other,
              live: () {
                if (++checks == 4) {
                  // revoke changes pending denial synchronously, before this predicate
                  // returns. The final guard must check denial after evaluating it.
                  denial = authority.revoke(uid: _uid);
                }
                return true;
              })),
      throwsA(isA<LocalReadGrantException>().having(
          (e) => e.reason, 'reason', LocalReadGrantFailure.denialPending)),
    );
    await denialStarted.future;
    release.complete();
    await commit;
    await denial;
    expect(checks, 4);
    expect(denial, isNotNull);
    expect(store.record!.uid, _other);
    expect(store.record!.state, LocalReadGrantState.blocked);
  });

  group('a pending denial blocks every grant that is not yet exposed', () {
    Matcher denialPending() => throwsA(isA<LocalReadGrantException>().having(
        (e) => e.reason, 'reason', LocalReadGrantFailure.denialPending));

    test(
        'reserved (preparing landed) before revoke(A) could neither read nor '
        'write: the commit is refused even after storage recovers', () async {
      await grant(uid: _uid);
      final issueB =
          await authority.beginIssue(uid: _other, replicaId: _replica);
      store.failReads = true;
      store.failWrites = true;
      expect(await authority.revoke(uid: _uid), LocalReadRevocation.incomplete);
      store.failReads = false;
      store.failWrites = false;
      store.attempts.clear();

      await expectLater(
          authority.commit(issueB, proof: proof(uid: _other)), denialPending());
      expect(store.attempts, isEmpty, reason: 'no committed write dispatched');
      expect(store.record!.state, LocalReadGrantState.preparing);
      expect(store.record!.operationId, issueB.operationId);
      expect(authority.isDenialPending, isTrue,
          reason: 'still incomplete: nothing invented about restart');
    });

    test('queued (not yet dispatched) preparing write never runs', () async {
      await grant(uid: _uid);
      store.failWrites = true;
      store.attempts.clear();
      final bResult = expectLater(
          authority.beginIssue(uid: _other, replicaId: _replica),
          denialPending());
      final revoked = await authority.revoke(uid: _uid);
      await bResult;
      expect(revoked, LocalReadRevocation.incomplete);
      expect(
          store.attempts
              .map((a) => LocalReadGrantRecord.tryDecode(a)!)
              .map((r) => '${r.uid}:${r.state.name}'),
          ['$_uid:blocked'],
          reason:
              'only the deny was attempted; the queued issue wrote nothing');
      expect(store.record!.state, LocalReadGrantState.committed,
          reason: 'storage still holds the old grant: no restart guarantee');
    });

    test(
        'a preparing write dispatched before revoke(A) lands but no issue '
        'is handed out', () async {
      await grant(uid: _uid);
      final dispatched = Completer<void>();
      final release = Completer<void>();
      store.onWrite = (r) async {
        if (r.uid == _other && r.state == LocalReadGrantState.preparing) {
          dispatched.complete();
          await release.future;
        }
      };
      final bResult = expectLater(
          authority.beginIssue(uid: _other, replicaId: _replica),
          denialPending());
      await dispatched.future;
      final revoked = authority.revoke(uid: _uid);
      expect(authority.isDenialPending, isTrue);
      release.complete();
      await bResult;
      await revoked;
      expect(store.record!.state, LocalReadGrantState.preparing,
          reason: 'preparing is durable and denies');
      expect(store.record!.uid, _other);
    });

    test('queued commit is refused in the lane before it writes', () async {
      final issueB =
          await authority.beginIssue(uid: _other, replicaId: _replica);
      store.failReads = true;
      store.failWrites = true;
      store.attempts.clear();
      final commitResult = expectLater(
          authority.commit(issueB, proof: proof(uid: _other)), denialPending());
      final revoked = await authority.revoke(uid: _uid);
      await commitResult;
      expect(revoked, LocalReadRevocation.incomplete);
      expect(
          store.attempts
              .map((a) => LocalReadGrantRecord.tryDecode(a)!)
              .map((r) => '${r.uid}:${r.state.name}'),
          ['$_uid:blocked']);
    });

    test(
        'a commit write dispatched before revoke(A) exposes no capability '
        'and is blocked', () async {
      final issueB =
          await authority.beginIssue(uid: _other, replicaId: _replica);
      final dispatched = Completer<void>();
      final release = Completer<void>();
      store.onWrite = (r) async {
        if (r.state == LocalReadGrantState.committed) {
          dispatched.complete();
          await release.future;
        }
      };
      final commitResult = expectLater(
          authority.commit(issueB, proof: proof(uid: _other)), denialPending());
      await dispatched.future;
      final revoked = authority.revoke(uid: _uid);
      release.complete();
      await commitResult;
      await revoked;
      expect(
          store.landed
              .map((a) => LocalReadGrantRecord.tryDecode(a)!)
              .map((r) => '${r.uid}:${r.state.name}'),
          ['$_other:preparing', '$_other:committed', '$_other:blocked'],
          reason: 'the dispatched grant landed, then the same operation was '
              'blocked before anything was exposed');
    });

    test(
        'an already-committed grant of another uid survives revoke(A) that '
        'could neither read nor write', () async {
      final capabilityB = await grant(uid: _other);
      store.failReads = true;
      store.failWrites = true;
      expect(await authority.revoke(uid: _uid), LocalReadRevocation.incomplete);
      store.failReads = false;
      store.failWrites = false;
      expect(capabilityB.isCurrent, isTrue, reason: 'no gratuitous revocation');
      expect(store.record!.state, LocalReadGrantState.committed);
      expect(store.record!.uid, _other);
      expect(authority.isDenialPending, isTrue);
    });
  });

  group('revocation is reported truthfully', () {
    test('a landed blocked record is durable', () async {
      await grant();
      expect(await authority.revoke(uid: _uid), LocalReadRevocation.denied);
      expect(store.record!.state, LocalReadGrantState.blocked);
      expect(store.record!.uid, _uid);
      expect(store.record!.replicaId, _replica);
    });

    test('every persistent write failing is incomplete, never durable',
        () async {
      final capability = await grant();
      store.failWrites = true;
      final result = await authority.revoke(uid: _uid);
      expect(result, LocalReadRevocation.incomplete);
      expect(result.isDurable, isFalse);
      expect(capability.isCurrent, isFalse, reason: 'locked in this process');
      expect(store.record!.state, LocalReadGrantState.committed,
          reason: 'storage still holds the old grant: no restart guarantee');
      expect(authority.isDenialPending, isTrue);
    });

    test(
        'while a denial is pending nothing new may be issued; a retry '
        'completes it', () async {
      await grant();
      store.failWrites = true;
      expect(await authority.revoke(uid: _uid), LocalReadRevocation.incomplete);
      await expectLater(authority.beginIssue(uid: _uid, replicaId: _replica),
          throwsA(isA<LocalReadGrantException>()));

      store.failWrites = false;
      expect(await authority.revoke(uid: _uid), LocalReadRevocation.denied);
      expect(authority.isDenialPending, isFalse);
      expect(store.record!.state, LocalReadGrantState.blocked);
      await authority.beginIssue(uid: _uid, replicaId: _replica);
    });

    test('a registry lock counts only when it confirms itself', () async {
      await grant();
      store.failWrites = true;
      expect(await authority.revoke(uid: _uid, lockRegistry: () async => false),
          LocalReadRevocation.incomplete);
      expect(
          await authority.revoke(
              uid: _uid, lockRegistry: () async => throw StateError('x')),
          LocalReadRevocation.incomplete);
      expect(authority.isDenialPending, isTrue);

      final result =
          await authority.revoke(uid: _uid, lockRegistry: () async => true);
      expect(result, LocalReadRevocation.registryLocked);
      expect(result.isDurable, isTrue);
      expect(authority.isDenialPending, isFalse);
    });

    test('an unreadable store still gets a blocked record attempt', () async {
      await grant();
      store.failReads = true;
      store.attempts.clear();
      // The write cannot be read back, so it is not claimed durable.
      expect(await authority.revoke(uid: _uid), LocalReadRevocation.incomplete);
      expect(store.attempts, hasLength(1));
      expect(LocalReadGrantRecord.tryDecode(store.attempts.single)!.state,
          LocalReadGrantState.blocked);
    });

    test('a store that holds nothing is already denying: no write', () async {
      expect(await authority.revoke(uid: _uid), LocalReadRevocation.denied);
      expect(store.attempts, isEmpty);
    });

    test('malformed stored state is overwritten with a blocked record',
        () async {
      store.value = 'garbage';
      expect(await authority.revoke(uid: _uid), LocalReadRevocation.denied);
      expect(store.record!.state, LocalReadGrantState.blocked);
    });

    test("another uid's grant is left intact", () async {
      final capability = await grant(uid: _other);
      store.attempts.clear();
      expect(await authority.revoke(uid: _uid), LocalReadRevocation.denied);
      expect(store.attempts, isEmpty);
      expect(capability.isCurrent, isTrue);
      expect(store.record!.state, LocalReadGrantState.committed);
      expect(store.record!.uid, _other);
    });
  });
}
