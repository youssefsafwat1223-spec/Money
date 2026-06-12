import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

class EncryptedBackupBlob {
  const EncryptedBackupBlob({
    required this.version,
    required this.salt,
    required this.nonce,
    required this.cipherText,
    required this.mac,
  });

  final int version;
  final List<int> salt;
  final List<int> nonce;
  final List<int> cipherText;
  final List<int> mac;

  Uint8List toBytes() {
    final json = {
      'version': version,
      'kdf': 'argon2id',
      'cipher': 'aes-256-gcm',
      'salt': base64Encode(salt),
      'nonce': base64Encode(nonce),
      'cipherText': base64Encode(cipherText),
      'mac': base64Encode(mac),
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(json)));
  }

  static EncryptedBackupBlob fromBytes(List<int> bytes) {
    final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    return EncryptedBackupBlob(
      version: json['version'] as int,
      salt: base64Decode(json['salt'] as String),
      nonce: base64Decode(json['nonce'] as String),
      cipherText: base64Decode(json['cipherText'] as String),
      mac: base64Decode(json['mac'] as String),
    );
  }
}

class BackupCrypto {
  BackupCrypto({
    Argon2id? kdf,
    AesGcm? cipher,
    Random? random,
  })  : _kdf = kdf ??
            Argon2id(
              memory: 64 * 1024,
              parallelism: 2,
              iterations: 3,
              hashLength: 32,
            ),
        _cipher = cipher ?? AesGcm.with256bits(),
        _random = random ?? Random.secure();

  final Argon2id _kdf;
  final AesGcm _cipher;
  final Random _random;

  List<int> randomBytes(int length) =>
      List<int>.generate(length, (_) => _random.nextInt(256));

  Future<SecretKey> deriveKey({
    required String passphrase,
    required List<int> salt,
  }) {
    return _kdf.deriveKey(
      secretKey: SecretKey(utf8.encode(passphrase)),
      nonce: salt,
    );
  }

  Future<EncryptedBackupBlob> encryptJson({
    required Map<String, dynamic> json,
    required String passphrase,
    List<int>? salt,
  }) async {
    final resolvedSalt = salt ?? randomBytes(16);
    final key = await deriveKey(passphrase: passphrase, salt: resolvedSalt);
    return encryptJsonWithKey(json: json, key: key, salt: resolvedSalt);
  }

  Future<EncryptedBackupBlob> encryptJsonWithKey({
    required Map<String, dynamic> json,
    required SecretKey key,
    required List<int> salt,
  }) async {
    final nonce = randomBytes(12);
    final box = await _cipher.encrypt(
      utf8.encode(jsonEncode(json)),
      secretKey: key,
      nonce: nonce,
    );
    return EncryptedBackupBlob(
      version: 1,
      salt: salt,
      nonce: nonce,
      cipherText: box.cipherText,
      mac: box.mac.bytes,
    );
  }

  Future<Map<String, dynamic>> decryptJson({
    required EncryptedBackupBlob blob,
    required String passphrase,
  }) async {
    final key = await deriveKey(passphrase: passphrase, salt: blob.salt);
    final clear = await _cipher.decrypt(
      SecretBox(
        blob.cipherText,
        nonce: blob.nonce,
        mac: Mac(blob.mac),
      ),
      secretKey: key,
    );
    return jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
  }
}
