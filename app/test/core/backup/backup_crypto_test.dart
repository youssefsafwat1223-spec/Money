import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:money_companion/core/backup/backup_crypto.dart';

void main() {
  test('encrypted backup crypto round-trips JSON and rejects wrong passphrase',
      () async {
    final crypto = BackupCrypto(
      kdf: Argon2id(
        memory: 1024,
        parallelism: 1,
        iterations: 1,
        hashLength: 32,
      ),
    );
    final payload = {
      'version': 1,
      'tables': {
        'transactions': [
          {'id': 'tx_1', 'amount': 42.5}
        ],
      },
    };

    final blob = await crypto.encryptJson(
      json: payload,
      passphrase: 'correct horse battery staple',
      salt: List<int>.filled(16, 7),
    );

    final restored = await crypto.decryptJson(
      blob: BackupCryptoBlobCompat.from(blob),
      passphrase: 'correct horse battery staple',
    );
    expect(restored, payload);

    expect(
      () => crypto.decryptJson(blob: blob, passphrase: 'wrong passphrase'),
      throwsA(isA<Exception>()),
    );
  });

  test('encrypted backup opens with password or recovery code', () async {
    final crypto = BackupCrypto(
      kdf: Argon2id(
        memory: 1024,
        parallelism: 1,
        iterations: 1,
        hashLength: 32,
      ),
    );
    final payload = {
      'version': 1,
      'tables': {
        'budgets': [
          {'id': 'budget_1', 'amount': 1200}
        ],
      },
    };
    final keyBytes = List<int>.generate(32, (index) => index);
    final slots = [
      await crypto.createKeySlot(
        type: 'password',
        secret: 'strong backup password',
        keyBytes: keyBytes,
      ),
      await crypto.createKeySlot(
        type: 'recovery',
        secret: 'ABCD-EFGH-JKLM',
        keyBytes: keyBytes,
      ),
    ];

    final blob = await crypto.encryptJsonWithRawKey(
      json: payload,
      keyBytes: keyBytes,
      keySlots: slots,
      salt: List<int>.filled(16, 3),
    );
    final parsed = EncryptedBackupBlob.fromBytes(blob.toBytes());

    expect(parsed.version, 2);
    expect(
      await crypto.decryptJson(
        blob: parsed,
        passphrase: 'strong backup password',
      ),
      payload,
    );
    expect(
      await crypto.decryptJson(blob: parsed, passphrase: 'abcd efgh jklm'),
      payload,
    );
    expect(
      () => crypto.decryptJson(blob: parsed, passphrase: 'wrong secret'),
      throwsA(isA<Exception>()),
    );
  });

  test('upgraded legacy backup still opens with original password', () async {
    final crypto = BackupCrypto(
      kdf: Argon2id(
        memory: 1024,
        parallelism: 1,
        iterations: 1,
        hashLength: 32,
      ),
    );
    final payload = {
      'version': 1,
      'tables': {
        'goals': [
          {'id': 'goal_1', 'target_amount': 5000}
        ],
      },
    };
    final salt = List<int>.filled(16, 8);
    final legacyKey = await crypto.deriveKey(
      passphrase: 'old backup password',
      salt: salt,
    );
    final keyBytes = await legacyKey.extractBytes();
    final slots = [
      await crypto.createKeySlot(
        type: 'recovery',
        secret: 'WXYZ-2345-6789',
        keyBytes: keyBytes,
      ),
    ];

    final upgradedBlob = await crypto.encryptJsonWithRawKey(
      json: payload,
      keyBytes: keyBytes,
      keySlots: slots,
      salt: salt,
    );
    final parsed = EncryptedBackupBlob.fromBytes(upgradedBlob.toBytes());

    expect(
      await crypto.decryptJson(blob: parsed, passphrase: 'old backup password'),
      payload,
    );
    expect(
      await crypto.decryptJson(blob: parsed, passphrase: 'wxyz23456789'),
      payload,
    );
  });

  test(
      'a v2 blob whose BODY is sealed with the legacy passphrase key still '
      'restores — the SecretBoxAuthenticationError fallback must be reachable',
      () async {
    // REGRESSION. `decryptJson` returned `decryptJsonWithRawKey(...)` from
    // inside its own `try` without awaiting it, so the authentication failure
    // raised during decryption escaped the `on SecretBoxAuthenticationError`
    // handler and the legacy-key fallback below it was unreachable. This blob is
    // exactly the shape that fallback exists for: key slots that unwrap cleanly,
    // over a body only the passphrase-derived key opens. Before the fix this
    // threw, and a user restoring an older backup lost it.
    final crypto = BackupCrypto(
      kdf: Argon2id(
        memory: 1024,
        parallelism: 1,
        iterations: 1,
        hashLength: 32,
      ),
    );
    const passphrase = 'legacy backup password';
    final salt = List<int>.filled(16, 11);
    final payload = {
      'version': 1,
      'tables': {
        'transactions': [
          {'id': 'tx_legacy', 'amount_minor': 77700, 'currency': 'SAR'}
        ],
      },
    };

    // Body sealed with the LEGACY passphrase-derived key.
    final legacyKey = await crypto.deriveKey(passphrase: passphrase, salt: salt);
    final legacyBlob = await crypto.encryptJsonWithKey(
      json: payload,
      key: legacyKey,
      salt: salt,
    );

    // A slot keyed to THIS passphrase, so `unwrapKeyFromSlots` SUCCEEDS — but
    // wrapping the wrong key, so only the decryption underneath it fails. That
    // is the one ordering that reaches the fallback; a slot whose secret does
    // not match fails inside the awaited unwrap and exits through a path that
    // already worked.
    final otherKey = await crypto.deriveKey(
      passphrase: 'a different key entirely',
      salt: List<int>.filled(16, 12),
    );
    final slots = [
      await crypto.createKeySlot(
        type: 'passphrase',
        secret: passphrase,
        keyBytes: await otherKey.extractBytes(),
      ),
    ];

    final mixedBlob = EncryptedBackupBlob(
      version: 2,
      salt: legacyBlob.salt,
      nonce: legacyBlob.nonce,
      cipherText: legacyBlob.cipherText,
      mac: legacyBlob.mac,
      keySlots: slots,
    );

    expect(
      await crypto.decryptJson(blob: mixedBlob, passphrase: passphrase),
      equals(payload),
    );
  });
}

class BackupCryptoBlobCompat {
  static EncryptedBackupBlob from(EncryptedBackupBlob blob) {
    return EncryptedBackupBlob.fromBytes(blob.toBytes());
  }
}
