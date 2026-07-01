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
}

class BackupCryptoBlobCompat {
  static EncryptedBackupBlob from(EncryptedBackupBlob blob) {
    return EncryptedBackupBlob.fromBytes(blob.toBytes());
  }
}
