@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backup/encrypted_backup_service.dart';

/// Cross-model audit **H-23** (backup crypto shared across accounts) and
/// **S-1** (v2 envelope-version ordering).
///
/// ## H-23 — what was actually wrong
///
/// All seven backup-crypto keys (`backup_enabled`, `backup_salt`,
/// `backup_recovery_code`, `backup_local_key`, `backup_key_slots`,
/// `backup_envelope_version`, `backup_last_at`) are device-global and carried
/// NO owner. `AppSession.signOut()` clears session keys but not these, so:
///
///   A enables backup → A signs out → B signs in → `backupNow()` still sees
///   `backup_enabled == '1'` and encrypts **B's data with A's content key**,
///   whose slots are wrapped by A's passphrase and recovery code, then uploads
///   it under B's path.
///
/// A could decrypt B's backup; B was "protected" by a secret they never chose.
///
/// The state remains DEVICE-scoped — it is a cache for *creating* backups — but
/// is now bound to one account and inert for any other. That costs no
/// recoverability, because key slots are serialized into the blob itself, so a
/// restore needs only the blob plus the passphrase or recovery code.
const _service = 'lib/core/backup/encrypted_backup_service.dart';
String get _source => File(_service).readAsStringSync();

void main() {
  group('H-23 — ownership decision is fail-closed', () {
    test('the owning account may use its own state', () {
      expect(
        classifyBackupStateOwnership(
          currentUserId: 'A',
          storedOwnerUid: 'A',
          localDataOwnerUid: 'A',
        ),
        BackupStateOwnership.owned,
      );
    });

    test('another account may NOT — this is the H-23 case', () {
      expect(
        classifyBackupStateOwnership(
          currentUserId: 'B',
          storedOwnerUid: 'A',
          localDataOwnerUid: 'A',
        ),
        BackupStateOwnership.foreign,
        reason: "B must never encrypt with A's content key",
      );
      // …even when B has since taken over the local database.
      expect(
        classifyBackupStateOwnership(
          currentUserId: 'B',
          storedOwnerUid: 'A',
          localDataOwnerUid: 'B',
        ),
        BackupStateOwnership.foreign,
        reason: 'an explicit owner marker always wins over inference',
      );
    });

    test('legacy state is adopted ONLY by the local-data owner', () {
      // Deterministic migration for state written before owner binding.
      expect(
        classifyBackupStateOwnership(
          currentUserId: 'A',
          storedOwnerUid: null,
          localDataOwnerUid: 'A',
        ),
        BackupStateOwnership.adoptable,
      );
      expect(
        classifyBackupStateOwnership(
          currentUserId: 'B',
          storedOwnerUid: null,
          localDataOwnerUid: 'A',
        ),
        BackupStateOwnership.foreign,
        reason: 'unowned state must not be claimed by whoever signs in next',
      );
    });

    test('every ambiguous combination resolves to foreign', () {
      for (final (owner, localOwner) in const [
        (null, null),
        (null, ''),
        ('', null),
        ('', ''),
      ]) {
        expect(
          classifyBackupStateOwnership(
            currentUserId: 'A',
            storedOwnerUid: owner,
            localDataOwnerUid: localOwner,
          ),
          BackupStateOwnership.foreign,
          reason:
              'ambiguity must cost a re-enable, never a mis-encrypted backup',
        );
      }
      // A signed-out read can never be "owned".
      expect(
        classifyBackupStateOwnership(
          currentUserId: '',
          storedOwnerUid: 'A',
          localDataOwnerUid: 'A',
        ),
        BackupStateOwnership.foreign,
      );
    });

    test('A → sign out → B → A signs back in: A still owns its state', () {
      // Sign-out deliberately does NOT delete the cache (that would cost
      // recoverability), so the same account must find it again.
      const stored = 'A';
      expect(
        classifyBackupStateOwnership(
            currentUserId: 'B', storedOwnerUid: stored, localDataOwnerUid: 'B'),
        BackupStateOwnership.foreign,
      );
      expect(
        classifyBackupStateOwnership(
            currentUserId: 'A', storedOwnerUid: stored, localDataOwnerUid: 'A'),
        BackupStateOwnership.owned,
      );
    });
  });

  group('H-23 — the decision is wired into every consuming path', () {
    test('backupNow refuses before reading any key material', () {
      final body =
          _source.substring(_source.indexOf('Future<void> backupNow()'));
      final method = body.substring(0, body.indexOf('\n  }'));
      final gateAt = method.indexOf('_ownedByCurrentAccount');
      final keyReadAt = method.indexOf('_localKeyKey');
      expect(gateAt, greaterThan(-1), reason: 'backupNow must check ownership');
      expect(keyReadAt, greaterThan(-1));
      expect(gateAt, lessThan(keyReadAt),
          reason: "the gate must precede reading another account's key");
    });

    test('status does not surface another account\'s backup as enabled', () {
      final body =
          _source.substring(_source.indexOf('Future<BackupStatus> status()'));
      final method = body.substring(0, body.indexOf('\n  }'));
      expect(method, contains('_ownedByCurrentAccount'));
    });

    test('enable() records the owner', () {
      final body = _source.substring(_source.indexOf('Future<String> enable('));
      final method = body.substring(0, body.indexOf('\n  }'));
      expect(method, contains('_ownerKey'));
    });

    test('clearing local state retires the owner marker too', () {
      final body = _source.substring(_source.indexOf('_clearLocalBackupState'));
      expect(body, contains('_ownerKey'));
    });

    test('H-8 interaction: the SQLCipher key is untouched here', () {
      // H-8 deliberately preserves the DB key across a wipe. Backup crypto must
      // not be made to survive in the same way — and this service must not
      // reach for the database key at all.
      expect(_source.contains('SecureDatabaseKeyStore'), isFalse);
      expect(_source.contains('money_companion.db_key'), isFalse);
    });
  });

  group('S-1 — write-new / verify / retire-old', () {
    String branchesOf() {
      final start =
          _source.indexOf('Future<void> _persistKeyStateAfterRestore');
      expect(start, greaterThan(-1), reason: 'method not found');
      // Bound at the NEXT member declaration rather than the first
      // two-space-indented brace — the method now contains nested closures.
      final after = _source.substring(start);
      final end = after.indexOf(RegExp(r'\n  (?:@|///|[A-Za-z<].*\()'), 50);
      return end > 0 ? after.substring(0, end) : after;
    }

    test('no branch deletes a version marker before writing its successor', () {
      final method = branchesOf();
      // The v2 branch is the reported S-1 case: it deleted the envelope-version
      // marker FIRST, so a crash left the marker gone with no successor written.
      final v2Start = method.indexOf('} else if (keyBytes == null) {');
      expect(v2Start, greaterThan(-1));
      final v2 = method.substring(v2Start, method.indexOf('} else {', v2Start));
      final writeAt = v2.indexOf('_localKeyKey');
      final retireAt = v2.indexOf('await retire(');
      expect(writeAt, greaterThan(-1));
      expect(retireAt, greaterThan(-1));
      expect(writeAt, lessThan(retireAt),
          reason: 'successor material must be durable before the superseded '
              'marker is retired');
    });

    test('every branch writes and verifies before retiring', () {
      final method = branchesOf();
      final verifies =
          RegExp(r'await _writeAndVerifyKeyState\(').allMatches(method).length;
      final retires = RegExp(r'await retire\(').allMatches(method).length;
      expect(verifies, 4,
          reason:
              'all three material branches and the owner publication verify');
      expect(retires, 3);
      // And in each branch verify precedes retire.
      var cursor = 0;
      for (var i = 0; i < 3; i++) {
        final v = method.indexOf('await _writeAndVerifyKeyState(', cursor);
        final r = method.indexOf('await retire(', v);
        expect(v, greaterThan(-1));
        expect(r, greaterThan(v),
            reason: 'retire must follow verify in every branch');
        cursor = r;
      }
    });

    test('an unreadable successor fails closed instead of retiring', () {
      final helper = _source
          .substring(_source.indexOf('Future<void> _writeAndVerifyKeyState'));
      expect(helper, contains('!= entry.value'),
          reason: 'verification must reject stale non-empty values too');
      expect(helper, contains('BackupException'),
          reason: 'if a written value cannot be read back, the migration must '
              'abort with the old markers still intact');
    });

    test('the envelope is not upgraded until the migration is committed', () {
      // v3 branch writes the version marker with its material, then retires the
      // v2-era salt/recovery — never the reverse.
      final method = branchesOf();
      final v3 = method.substring(method.indexOf('if (blob.version >= 3) {'),
          method.indexOf('} else if (keyBytes == null) {'));
      final versionWrite = v3.indexOf("_envelopeVersionKey: '3'");
      final retire = v3.indexOf('retire(');
      expect(versionWrite, greaterThan(-1));
      expect(versionWrite, lessThan(retire));
    });

    test('a restore binds the state to the restoring account (H-23)', () {
      final method = branchesOf();
      expect(method, contains('_ownerKey'),
          reason: 'restoring establishes backup state for the CURRENT account');
    });
  });

  group('Batch 12 — no format change was required', () {
    test('the envelope versions and their meanings are unchanged', () {
      // The fix is local metadata only: owner binding + write ordering. No
      // public backup format was redesigned, so old backups stay restorable.
      expect(_source, contains("_envelopeVersionKey: '3'"));
      expect(_source, contains('blob.version >= 3'),
          reason: 'v3 handling unchanged');
      expect(_source, contains('keyBytes == null'),
          reason: 'the v2 branch still exists for legacy envelopes');
    });

    test('the owner marker is local-only and never leaves the device', () {
      // It must not be uploaded with the blob or into the metadata row.
      final upload = _source.substring(
          _source.indexOf('static Map<String, dynamic> uploadMetadata'));
      expect(
          upload.substring(0, upload.indexOf('};')).contains('owner'), isFalse,
          reason: 'the ownership marker is device-local bookkeeping, not part '
              'of the backup format');
    });
  });
}
