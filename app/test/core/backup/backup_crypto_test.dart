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
}

class BackupCryptoBlobCompat {
  static EncryptedBackupBlob from(EncryptedBackupBlob blob) {
    return EncryptedBackupBlob.fromBytes(blob.toBytes());
  }
}
