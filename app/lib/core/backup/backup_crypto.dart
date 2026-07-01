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
    this.keySlots = const [],
  });

  final int version;
  final List<int> salt;
  final List<int> nonce;
  final List<int> cipherText;
  final List<int> mac;
  final List<BackupKeySlot> keySlots;

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
    if (keySlots.isNotEmpty) {
      json['keySlots'] = keySlots.map((slot) => slot.toJson()).toList();
    }
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
      keySlots: BackupKeySlot.listFromJson(json['keySlots']),
    );
  }
}

class BackupKeySlot {
  const BackupKeySlot({
    required this.type,
    required this.salt,
    required this.nonce,
    required this.cipherText,
    required this.mac,
  });

  final String type;
  final List<int> salt;
  final List<int> nonce;
  final List<int> cipherText;
  final List<int> mac;

  Map<String, Object?> toJson() {
    return {
      'type': type,
      'salt': base64Encode(salt),
      'nonce': base64Encode(nonce),
      'cipherText': base64Encode(cipherText),
      'mac': base64Encode(mac),
    };
  }

  static BackupKeySlot fromJson(Map<String, dynamic> json) {
    return BackupKeySlot(
      type: json['type'] as String? ?? 'password',
      salt: base64Decode(json['salt'] as String),
      nonce: base64Decode(json['nonce'] as String),
      cipherText: base64Decode(json['cipherText'] as String),
      mac: base64Decode(json['mac'] as String),
    );
  }

  static List<BackupKeySlot> listFromJson(Object? value) {
    if (value is! List) return const [];
    return value
        .whereType<Map<Object?, Object?>>()
        .map((item) => BackupKeySlot.fromJson(
              item.map((key, val) => MapEntry(key.toString(), val)),
            ))
        .toList(growable: false);
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

  Future<BackupKeySlot> createKeySlot({
    required String type,
    required String secret,
    required List<int> keyBytes,
  }) async {
    final salt = randomBytes(16);
    final wrappingKey = await deriveKey(
      passphrase: _secretForSlot(type, secret),
      salt: salt,
    );
    final nonce = randomBytes(12);
    final box = await _cipher.encrypt(
      keyBytes,
      secretKey: wrappingKey,
      nonce: nonce,
    );
    return BackupKeySlot(
      type: type,
      salt: salt,
      nonce: nonce,
      cipherText: box.cipherText,
      mac: box.mac.bytes,
    );
  }

  Future<EncryptedBackupBlob> encryptJsonWithRawKey({
    required Map<String, dynamic> json,
    required List<int> keyBytes,
    required List<BackupKeySlot> keySlots,
    List<int>? salt,
  }) async {
    final resolvedSalt = salt ?? randomBytes(16);
    final base = await encryptJsonWithKey(
      json: json,
      key: SecretKey(keyBytes),
      salt: resolvedSalt,
    );
    return EncryptedBackupBlob(
      version: keySlots.isEmpty ? 1 : 2,
      salt: base.salt,
      nonce: base.nonce,
      cipherText: base.cipherText,
      mac: base.mac,
      keySlots: keySlots,
    );
  }

  Future<Map<String, dynamic>> decryptJson({
    required EncryptedBackupBlob blob,
    required String passphrase,
  }) async {
    if (blob.keySlots.isNotEmpty) {
      try {
        final keyBytes = await unwrapKeyFromSlots(
          keySlots: blob.keySlots,
          secret: passphrase,
        );
        return decryptJsonWithRawKey(blob: blob, keyBytes: keyBytes);
      } on SecretBoxAuthenticationError {
        final legacyKey = await deriveKey(
          passphrase: passphrase,
          salt: blob.salt,
        );
        return decryptJsonWithKey(blob: blob, key: legacyKey);
      }
    }

    final key = await deriveKey(passphrase: passphrase, salt: blob.salt);
    return decryptJsonWithKey(blob: blob, key: key);
  }

  Future<Map<String, dynamic>> decryptJsonWithRawKey({
    required EncryptedBackupBlob blob,
    required List<int> keyBytes,
  }) {
    return decryptJsonWithKey(blob: blob, key: SecretKey(keyBytes));
  }

  Future<Map<String, dynamic>> decryptJsonWithKey({
    required EncryptedBackupBlob blob,
    required SecretKey key,
  }) async {
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

  Future<List<int>> unwrapKeyFromSlots({
    required List<BackupKeySlot> keySlots,
    required String secret,
  }) async {
    SecretBoxAuthenticationError? lastAuthError;
    for (final slot in keySlots) {
      try {
        final wrappingKey = await deriveKey(
          passphrase: _secretForSlot(slot.type, secret),
          salt: slot.salt,
        );
        return await _cipher.decrypt(
          SecretBox(
            slot.cipherText,
            nonce: slot.nonce,
            mac: Mac(slot.mac),
          ),
          secretKey: wrappingKey,
        );
      } on SecretBoxAuthenticationError catch (error) {
        lastAuthError = error;
      }
    }
    throw lastAuthError ?? SecretBoxAuthenticationError();
  }

  String _secretForSlot(String type, String secret) {
    if (type == 'recovery') {
      return secret.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
    }
    return secret;
  }
}
