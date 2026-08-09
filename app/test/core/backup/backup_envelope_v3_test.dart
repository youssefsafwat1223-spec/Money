// Phase-7 test/harness reliability — this file exercises the v3 envelope's
// deliberately memory-hard Argon2id KDF (64 MiB / 3 iters / p=2) at PRODUCTION cost.
// It is tagged `crypto-prod` so the canonical gate runs it SERIALIZED
// (`flutter test --tags crypto-prod --concurrency=1`) and excludes it from the
// parallel bulk run — the real determinism fix. Reason: cryptography 2.9.0 guards
// each Argon2 segment with a HARDCODED 10s per-segment isolate timeout that no
// `@Timeout` can raise; under a saturated parallel suite a starved segment trips it
// (`StateError('Segment processing timeout')`). Serializing gives the derivation an
// uncontended core so every segment finishes in ~1s. The generous file-wide
// `@Timeout` is a secondary framework-level guard, NOT the fix. TEST-ONLY: no change
// to the envelope, KDF parameters, or any crypto/financial behavior.
@Tags(['crypto-prod'])
@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backup/backup_crypto.dart';

// MALI-076n / MALI-014 — the current (v3) authenticated backup envelope.
void main() {
  final crypto = BackupCrypto();
  const passphrase = 'correct horse battery staple';
  const recovery = 'ABCD-EFGH-IJKL';
  final payload = {'schemaVersion': 3, 'country': 'SA', 'secret': 'ريال-💰-42'};

  // Encrypt ONCE and reuse across the tamper cases (Argon2id is memory-hard).
  late EncryptedBackupBlob blob;
  late Map<String, dynamic> wire;

  setUpAll(() async {
    blob = await crypto.encryptEnvelopeV3(
      json: payload,
      schemaVersion: 3,
      passphrase: passphrase,
      recoveryCode: recovery,
    );
    wire = jsonDecode(utf8.decode(blob.toBytes())) as Map<String, dynamic>;
  });

  Uint8List reserialize(Map<String, dynamic> m) =>
      Uint8List.fromList(utf8.encode(jsonEncode(m)));
  Map<String, dynamic> mutated(void Function(Map<String, dynamic>) f) {
    final copy = jsonDecode(jsonEncode(wire)) as Map<String, dynamic>;
    f(copy);
    return copy;
  }

  group('round-trip', () {
    test('normal passphrase decrypts', () async {
      final out = await crypto.decryptEnvelope(blob: blob, secret: passphrase);
      expect(out['secret'], 'ريال-💰-42');
    });

    test('recovery code decrypts the same content', () async {
      final out = await crypto.decryptEnvelope(blob: blob, secret: recovery);
      expect(out['country'], 'SA');
    });

    test('Arabic / emoji / whitespace / empty passphrases round-trip', () async {
      for (final p in ['كلمة السر', '💰🔐', '  spaced  ', '', 'CaSePreserved']) {
        final b = await crypto.encryptEnvelopeV3(
            json: payload, schemaVersion: 3, passphrase: p);
        final out = await crypto.decryptEnvelope(blob: b, secret: p);
        expect(out['country'], 'SA');
      }
    });

    test('leading/trailing whitespace is significant (no silent trim)', () async {
      final b = await crypto.encryptEnvelopeV3(
          json: payload, schemaVersion: 3, passphrase: '  pw  ');
      await expectLater(
        crypto.decryptEnvelope(blob: b, secret: 'pw'),
        throwsA(isA<BackupEnvelopeException>()),
      );
      expect((await crypto.decryptEnvelope(blob: b, secret: '  pw  '))['country'],
          'SA');
    });

    test('identical input + passphrase produces DIFFERENT blobs (fresh salt/nonce)',
        () async {
      final a = await crypto.encryptEnvelopeV3(
          json: payload, schemaVersion: 3, passphrase: passphrase);
      final b = await crypto.encryptEnvelopeV3(
          json: payload, schemaVersion: 3, passphrase: passphrase);
      expect(a.toBytes(), isNot(b.toBytes()));
      expect(a.nonce, isNot(b.nonce));
    });

    test('header is self-describing (magic + version + params); needs no external metadata',
        () {
      expect(wire['magic'], 'MALIBAK');
      expect(wire['envelopeVersion'], 3);
      expect(wire['cipher'], 'aes-256-gcm');
      expect(wire['kdf'], 'argon2id');
      expect((wire['kdfParams'] as Map)['memory'], 64 * 1024);
      expect(wire['compression'], 'none');
    });
  });

  group('authentication & corruption (all → authenticationFailed)', () {
    test('wrong passphrase', () async {
      await expectLater(crypto.decryptEnvelope(blob: blob, secret: 'nope'),
          throwsA(isA<BackupEnvelopeException>()));
    });

    for (final tamper in <String, void Function(Map<String, dynamic>)>{
      'ciphertext': (m) => m['cipherText'] = base64Encode([...base64Decode(m['cipherText'] as String)]..[0] ^= 0xFF),
      'auth tag': (m) => m['mac'] = base64Encode([...base64Decode(m['mac'] as String)]..[0] ^= 0xFF),
      'schema version (authenticated header)': (m) => m['schemaVersion'] = 999,
    }.entries) {
      test('modified ${tamper.key} fails authentication', () async {
        final tampered = EncryptedBackupBlob.fromBytesChecked(
            reserialize(mutated(tamper.value)));
        await expectLater(
          crypto.decryptEnvelope(blob: tampered, secret: passphrase),
          throwsA(predicate((e) =>
              e is BackupEnvelopeException &&
              e.kind == BackupEnvelopeErrorKind.authenticationFailed)),
        );
      });
    }
  });

  group('structural / resource-limit rejection (before any KDF)', () {
    test('unsafe KDF memory is rejected as unsafeKdfParams', () {
      expect(
        () => EncryptedBackupBlob.fromBytesChecked(reserialize(
            mutated((m) => (m['kdfParams'] as Map)['memory'] = 999999999))),
        throwsA(predicate((e) =>
            e is BackupEnvelopeException &&
            e.kind == BackupEnvelopeErrorKind.unsafeKdfParams)),
      );
    });

    test('an oversized declared ciphertext is payloadTooLarge', () {
      final huge = base64Encode(List<int>.filled(65 * 1024 * 1024, 0));
      expect(
        () => EncryptedBackupBlob.fromBytesChecked(
            reserialize(mutated((m) => m['cipherText'] = huge))),
        throwsA(predicate((e) =>
            e is BackupEnvelopeException &&
            e.kind == BackupEnvelopeErrorKind.payloadTooLarge)),
      );
    });

    test('unknown future version is unsupportedVersion', () {
      expect(
        () => EncryptedBackupBlob.fromBytesChecked(
            reserialize(mutated((m) => m['envelopeVersion'] = 99))),
        throwsA(predicate((e) =>
            e is BackupEnvelopeException &&
            e.kind == BackupEnvelopeErrorKind.unsupportedVersion)),
      );
    });

    test('an unsupported cipher/kdf id is unsupportedAlgorithm', () {
      expect(
        () => EncryptedBackupBlob.fromBytesChecked(
            reserialize(mutated((m) => m['cipher'] = 'rot13'))),
        throwsA(predicate((e) =>
            e is BackupEnvelopeException &&
            e.kind == BackupEnvelopeErrorKind.unsupportedAlgorithm)),
      );
    });

    test('truncated / garbage / random bytes are malformed', () {
      for (final bad in <List<int>>[
        utf8.encode('{ not json'),
        utf8.encode('{}'),
        List<int>.generate(64, (i) => (i * 7) % 256),
      ]) {
        expect(() => EncryptedBackupBlob.fromBytesChecked(bad),
            throwsA(isA<BackupEnvelopeException>()));
      }
    });
  });

  // The exact crypto flow the service uses: enable() derives slots for a content
  // key; a background backupNow() re-encrypts with the stored content key + slots
  // (NO passphrase); restore() unwraps the content key from a slot then decrypts.
  group('service key-management flow', () {
    test('stored content key + slots round-trip without the passphrase at backup',
        () async {
      final contentKey = crypto.randomBytes(32);
      final slots = await crypto.createV3KeySlots(
        contentKey: contentKey,
        passphrase: passphrase,
        recoveryCode: recovery,
      );
      // Background backup: no passphrase, reuse the stored content key + slots.
      final b = await crypto.encryptEnvelopeV3WithContentKey(
        json: payload,
        schemaVersion: 3,
        contentKey: contentKey,
        keySlots: slots,
      );
      // Restore with the passphrase (or recovery) unwraps the content key.
      final viaPass = await crypto.unwrapContentKeyV3(blob: b, secret: passphrase);
      expect(viaPass, contentKey);
      final viaRecovery = await crypto.unwrapContentKeyV3(blob: b, secret: recovery);
      expect(viaRecovery, contentKey);
      expect((await crypto.decryptPayloadV3(blob: b, contentKey: viaPass))['country'], 'SA');
    });

    test('stored slots survive a snapshot schema bump (slot AAD excludes schema)',
        () async {
      final contentKey = crypto.randomBytes(32);
      final slots = await crypto.createV3KeySlots(
          contentKey: contentKey, passphrase: passphrase);
      // A later backup at a DIFFERENT schema version reuses the same slots.
      final b = await crypto.encryptEnvelopeV3WithContentKey(
        json: payload, schemaVersion: 7, contentKey: contentKey, keySlots: slots,
      );
      final k = await crypto.unwrapContentKeyV3(blob: b, secret: passphrase);
      expect(k, contentKey);
    });
  });

  group('privacy', () {
    test('a typed error never contains the passphrase or key bytes', () {
      const e = BackupEnvelopeException(BackupEnvelopeErrorKind.authenticationFailed);
      expect(e.toString().contains(passphrase), isFalse);
      expect(e.toString(), 'BackupEnvelopeException(authenticationFailed)');
    });
  });

  // ── legacy compatibility (v1 direct, v2 slots) still readable ──────────────
  group('legacy compatibility', () {
    test('a v1 legacy blob still decrypts via decryptEnvelope', () async {
      final v1 = await crypto.encryptJson(json: payload, passphrase: passphrase);
      expect(v1.version, 1);
      final out = await crypto.decryptEnvelope(blob: v1, secret: passphrase);
      expect(out['country'], 'SA');
    });

    test('a v2 legacy slotted blob still decrypts with passphrase or recovery',
        () async {
      final rawKey = crypto.randomBytes(32);
      final slots = [
        await crypto.createKeySlot(type: 'password', secret: passphrase, keyBytes: rawKey),
        await crypto.createKeySlot(type: 'recovery', secret: recovery, keyBytes: rawKey),
      ];
      final v2 = await crypto.encryptJsonWithRawKey(
          json: payload, keyBytes: rawKey, keySlots: slots);
      expect(v2.version, 2);
      expect((await crypto.decryptEnvelope(blob: v2, secret: passphrase))['country'], 'SA');
      expect((await crypto.decryptEnvelope(blob: v2, secret: recovery))['country'], 'SA');
    });
  });
}
