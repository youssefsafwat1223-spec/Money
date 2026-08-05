import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

// ── MALI-076n / MALI-014 — versioned, authenticated backup envelope ──────────
//
// Envelope versions:
//   v1 — legacy: passphrase-derived key encrypts the payload directly.
//   v2 — legacy: a random content key encrypts the payload; password + recovery
//        key slots each AEAD-wrap the content key. Header UNAUTHENTICATED.
//   v3 — current: same content-key + slots model, but the security-sensitive
//        header (magic, versions, cipher, KDF id + parameters, compression) is
//        cryptographically bound to BOTH the payload and every slot via the
//        AES-GCM AAD, and the envelope declares a magic identifier. Only v3 is
//        ever WRITTEN; v1/v2/v3 can be READ.

/// Distinct, typed backup-envelope failures. Kept separate from
/// `LocalDatabaseKeyUnavailableException` (a missing DB key) and from database
/// corruption/open failures. Carries no passphrase, key, salt/nonce bytes,
/// plaintext, financial data, absolute path, or raw crypto-exception string.
enum BackupEnvelopeErrorKind {
  unsupportedVersion,
  malformed,
  unsupportedAlgorithm,
  unsafeKdfParams,
  payloadTooLarge,

  /// A wrong passphrase, tampering, and ciphertext corruption are
  /// cryptographically INDISTINGUISHABLE — all surface here.
  authenticationFailed,
  incompatibleSchema,
  decodeFailed,
}

class BackupEnvelopeException implements Exception {
  const BackupEnvelopeException(this.kind);
  final BackupEnvelopeErrorKind kind;
  @override
  String toString() => 'BackupEnvelopeException(${kind.name})';
}

/// Safe bounds for envelope parameters. Anything a downloaded (untrusted, not-yet
/// authenticated) blob declares is checked against these BEFORE the expensive KDF
/// runs, so a hostile blob cannot exhaust memory/CPU or overflow an allocation.
class BackupEnvelopeLimits {
  static const int minMemoryKib = 8 * 1024; // 8 MiB
  static const int maxMemoryKib = 256 * 1024; // 256 MiB
  static const int minIterations = 1;
  static const int maxIterations = 10;
  static const int minParallelism = 1;
  static const int maxParallelism = 4;
  static const int minHashLength = 16;
  static const int maxHashLength = 64;
  static const int minSaltLen = 16;
  static const int maxSaltLen = 64;
  static const int nonceLen = 12; // AES-GCM 96-bit nonce, fixed
  static const int maxCipherTextBytes = 64 * 1024 * 1024; // 64 MiB
  static const int maxSlots = 8;
  static const int maxEnvelopeChars = 96 * 1024 * 1024; // bound the raw blob
}

/// The v3 authenticated header. Its [aad] bytes are fed as AES-GCM additional
/// authenticated data to the payload and every slot, so any modification to a
/// security-sensitive field fails authentication before any restore mutation.
class BackupEnvelopeHeader {
  const BackupEnvelopeHeader({
    required this.envelopeVersion,
    required this.schemaVersion,
    required this.cipher,
    required this.kdf,
    required this.memoryKib,
    required this.iterations,
    required this.parallelism,
    required this.hashLength,
    required this.compression,
  });

  static const magic = 'MALIBAK';
  static const cipherAesGcm = 'aes-256-gcm';
  static const kdfArgon2id = 'argon2id';
  static const compressionNone = 'none';

  final int envelopeVersion;
  final int schemaVersion;
  final String cipher;
  final String kdf;
  final int memoryKib;
  final int iterations;
  final int parallelism;
  final int hashLength;
  final String compression;

  /// Deterministic, canonical AAD bytes (fixed field order; no JSON key-order
  /// ambiguity). Extended per slot by [slotAad].
  List<int> aad() => utf8.encode(
        '$magic|v=$envelopeVersion|schema=$schemaVersion|cipher=$cipher|'
        'kdf=$kdf|m=$memoryKib|t=$iterations|p=$parallelism|h=$hashLength|'
        'z=$compression',
      );

  /// Slot AAD deliberately EXCLUDES schemaVersion + compression (which describe
  /// the payload, not the key wrapping): slots wrap the content key and are
  /// stored/reused across backups, so they must stay valid across a snapshot
  /// schema bump. They still bind the magic, envelope version, cipher, and KDF
  /// parameters they were produced under.
  List<int> slotAad(String slotType) => utf8.encode(
        '$magic|v=$envelopeVersion|cipher=$cipher|kdf=$kdf|'
        'm=$memoryKib|t=$iterations|p=$parallelism|h=$hashLength|slot=$slotType',
      );

  Map<String, dynamic> toJson() => {
        'magic': magic,
        'envelopeVersion': envelopeVersion,
        'schemaVersion': schemaVersion,
        'cipher': cipher,
        'kdf': kdf,
        'kdfParams': {
          'memory': memoryKib,
          'iterations': iterations,
          'parallelism': parallelism,
          'hashLength': hashLength,
        },
        'compression': compression,
      };
}

/// Passphrase byte contract for the CURRENT (v3) envelope (MALI-076n §6):
/// the passphrase is encoded as raw UTF-8 with NO Unicode normalization, case is
/// preserved, and interior/leading/trailing whitespace is preserved EXACTLY —
/// v3 never silently trims. (Legacy v1/v2 keep their historical behavior via the
/// service layer.) Deterministic across platforms because Dart's utf8.encode is.
List<int> encodePassphraseV3(String passphrase) => utf8.encode(passphrase);

class EncryptedBackupBlob {
  const EncryptedBackupBlob({
    required this.version,
    required this.salt,
    required this.nonce,
    required this.cipherText,
    required this.mac,
    this.keySlots = const [],
    this.header,
  });

  final int version;
  final List<int> salt;
  final List<int> nonce;
  final List<int> cipherText;
  final List<int> mac;
  final List<BackupKeySlot> keySlots;

  /// Present only for v3 envelopes: the authenticated header bound as AES-GCM
  /// AAD to the payload and every slot.
  final BackupEnvelopeHeader? header;

  Uint8List toBytes() {
    if (version >= 3 && header != null) {
      final json = <String, dynamic>{
        ...header!.toJson(),
        'nonce': base64Encode(nonce),
        'cipherText': base64Encode(cipherText),
        'mac': base64Encode(mac),
        'keySlots': keySlots.map((slot) => slot.toJson()).toList(),
      };
      return Uint8List.fromList(utf8.encode(jsonEncode(json)));
    }
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

  /// Lenient legacy parser (v1/v2). Prefer [fromBytesChecked] for untrusted input.
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

  /// Structurally validate an UNTRUSTED envelope and enforce resource limits
  /// BEFORE any key derivation or decryption. Throws a typed
  /// [BackupEnvelopeException]; never runs the KDF here.
  static EncryptedBackupBlob fromBytesChecked(List<int> bytes) {
    if (bytes.length > BackupEnvelopeLimits.maxEnvelopeChars) {
      throw const BackupEnvelopeException(BackupEnvelopeErrorKind.payloadTooLarge);
    }
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } catch (_) {
      throw const BackupEnvelopeException(BackupEnvelopeErrorKind.malformed);
    }

    final version = json['version'] ?? json['envelopeVersion'];
    if (version is! int) {
      throw const BackupEnvelopeException(BackupEnvelopeErrorKind.malformed);
    }
    if (version < 1 || version > 3) {
      throw const BackupEnvelopeException(
          BackupEnvelopeErrorKind.unsupportedVersion);
    }

    List<int> b64(String field) {
      final v = json[field];
      if (v is! String) {
        throw const BackupEnvelopeException(BackupEnvelopeErrorKind.malformed);
      }
      try {
        return base64Decode(v);
      } catch (_) {
        throw const BackupEnvelopeException(BackupEnvelopeErrorKind.malformed);
      }
    }

    final nonce = b64('nonce');
    final cipherText = b64('cipherText');
    final mac = b64('mac');
    if (nonce.length != BackupEnvelopeLimits.nonceLen) {
      throw const BackupEnvelopeException(BackupEnvelopeErrorKind.malformed);
    }
    if (cipherText.length > BackupEnvelopeLimits.maxCipherTextBytes) {
      throw const BackupEnvelopeException(BackupEnvelopeErrorKind.payloadTooLarge);
    }

    BackupEnvelopeHeader? header;
    if (version >= 3) {
      if (json['magic'] != BackupEnvelopeHeader.magic) {
        throw const BackupEnvelopeException(BackupEnvelopeErrorKind.malformed);
      }
      if (json['cipher'] != BackupEnvelopeHeader.cipherAesGcm) {
        throw const BackupEnvelopeException(
            BackupEnvelopeErrorKind.unsupportedAlgorithm);
      }
      if (json['kdf'] != BackupEnvelopeHeader.kdfArgon2id) {
        throw const BackupEnvelopeException(
            BackupEnvelopeErrorKind.unsupportedAlgorithm);
      }
      final params = json['kdfParams'];
      if (params is! Map) {
        throw const BackupEnvelopeException(BackupEnvelopeErrorKind.malformed);
      }
      int intParam(String k) {
        final v = params[k];
        if (v is! int) {
          throw const BackupEnvelopeException(BackupEnvelopeErrorKind.malformed);
        }
        return v;
      }

      final memory = intParam('memory');
      final iterations = intParam('iterations');
      final parallelism = intParam('parallelism');
      final hashLength = intParam('hashLength');
      // Untrusted params → enforce safe bounds BEFORE the expensive KDF.
      if (memory < BackupEnvelopeLimits.minMemoryKib ||
          memory > BackupEnvelopeLimits.maxMemoryKib ||
          iterations < BackupEnvelopeLimits.minIterations ||
          iterations > BackupEnvelopeLimits.maxIterations ||
          parallelism < BackupEnvelopeLimits.minParallelism ||
          parallelism > BackupEnvelopeLimits.maxParallelism ||
          hashLength < BackupEnvelopeLimits.minHashLength ||
          hashLength > BackupEnvelopeLimits.maxHashLength) {
        throw const BackupEnvelopeException(
            BackupEnvelopeErrorKind.unsafeKdfParams);
      }
      final schemaVersion = json['schemaVersion'];
      if (schemaVersion is! int) {
        throw const BackupEnvelopeException(BackupEnvelopeErrorKind.malformed);
      }
      final compression = json['compression'];
      if (compression != BackupEnvelopeHeader.compressionNone) {
        throw const BackupEnvelopeException(
            BackupEnvelopeErrorKind.unsupportedAlgorithm);
      }
      header = BackupEnvelopeHeader(
        envelopeVersion: version,
        schemaVersion: schemaVersion,
        cipher: BackupEnvelopeHeader.cipherAesGcm,
        kdf: BackupEnvelopeHeader.kdfArgon2id,
        memoryKib: memory,
        iterations: iterations,
        parallelism: parallelism,
        hashLength: hashLength,
        compression: BackupEnvelopeHeader.compressionNone,
      );
    }

    final slots = BackupKeySlot.listFromJson(json['keySlots']);
    if (slots.length > BackupEnvelopeLimits.maxSlots) {
      throw const BackupEnvelopeException(BackupEnvelopeErrorKind.malformed);
    }
    for (final slot in slots) {
      if (slot.salt.length < BackupEnvelopeLimits.minSaltLen ||
          slot.salt.length > BackupEnvelopeLimits.maxSaltLen ||
          slot.nonce.length != BackupEnvelopeLimits.nonceLen ||
          slot.cipherText.length > BackupEnvelopeLimits.maxCipherTextBytes) {
        throw const BackupEnvelopeException(BackupEnvelopeErrorKind.malformed);
      }
    }

    // Legacy v1/v2 use the top-level salt for the passphrase KDF; v3 uses
    // per-slot salts (top-level salt is absent/vestigial).
    final salt = version >= 3 ? const <int>[] : b64('salt');
    if (version < 3 &&
        (salt.length < BackupEnvelopeLimits.minSaltLen ||
            salt.length > BackupEnvelopeLimits.maxSaltLen)) {
      throw const BackupEnvelopeException(BackupEnvelopeErrorKind.malformed);
    }

    return EncryptedBackupBlob(
      version: version,
      salt: salt,
      nonce: nonce,
      cipherText: cipherText,
      mac: mac,
      keySlots: slots,
      header: header,
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

  // ── v3 authenticated envelope ──────────────────────────────────────────────

  // Current write parameters (memory in KiB): 64 MiB / 3 / 2 / 32 bytes.
  static const int _v3MemoryKib = 64 * 1024;
  static const int _v3Iterations = 3;
  static const int _v3Parallelism = 2;
  static const int _v3HashLength = 32;

  BackupEnvelopeHeader defaultV3Header(int schemaVersion) => BackupEnvelopeHeader(
        envelopeVersion: 3,
        schemaVersion: schemaVersion,
        cipher: BackupEnvelopeHeader.cipherAesGcm,
        kdf: BackupEnvelopeHeader.kdfArgon2id,
        memoryKib: _v3MemoryKib,
        iterations: _v3Iterations,
        parallelism: _v3Parallelism,
        hashLength: _v3HashLength,
        compression: BackupEnvelopeHeader.compressionNone,
      );

  Future<SecretKey> _deriveArgon2id({
    required List<int> secret,
    required List<int> salt,
    required BackupEnvelopeHeader header,
  }) {
    final kdf = Argon2id(
      memory: header.memoryKib,
      parallelism: header.parallelism,
      iterations: header.iterations,
      hashLength: header.hashLength,
    );
    return kdf.deriveKey(secretKey: SecretKey(secret), nonce: salt);
  }

  // v3 slot secret bytes: password = exact UTF-8 (no trim/normalize, MALI-076n
  // §6); recovery = alnum-uppercased (a generated, format-stable code).
  List<int> _slotSecretBytes(String type, String secret) {
    if (type == 'recovery') {
      return utf8.encode(secret.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase());
    }
    return encodePassphraseV3(secret);
  }

  Future<BackupKeySlot> _wrapContentKeyV3({
    required BackupEnvelopeHeader header,
    required String slotType,
    required String slotSecret,
    required List<int> contentKey,
  }) async {
    final salt = randomBytes(16);
    final wrappingKey = await _deriveArgon2id(
      secret: _slotSecretBytes(slotType, slotSecret),
      salt: salt,
      header: header,
    );
    final nonce = randomBytes(BackupEnvelopeLimits.nonceLen);
    final box = await _cipher.encrypt(
      contentKey,
      secretKey: wrappingKey,
      nonce: nonce,
      aad: header.slotAad(slotType),
    );
    return BackupKeySlot(
      type: slotType,
      salt: salt,
      nonce: nonce,
      cipherText: box.cipherText,
      mac: box.mac.bytes,
    );
  }

  /// Encrypt [json] into a CURRENT (v3) authenticated envelope. A fresh random
  /// content key encrypts the payload (AAD = authenticated header); the content
  /// key is AEAD-wrapped by a password slot and, if provided, a recovery slot.
  Future<EncryptedBackupBlob> encryptEnvelopeV3({
    required Map<String, dynamic> json,
    required int schemaVersion,
    required String passphrase,
    String? recoveryCode,
  }) async {
    final header = defaultV3Header(schemaVersion);
    final contentKey = randomBytes(32);
    final nonce = randomBytes(BackupEnvelopeLimits.nonceLen);
    final box = await _cipher.encrypt(
      utf8.encode(jsonEncode(json)),
      secretKey: SecretKey(contentKey),
      nonce: nonce,
      aad: header.aad(),
    );
    final slots = <BackupKeySlot>[
      await _wrapContentKeyV3(
        header: header,
        slotType: 'password',
        slotSecret: passphrase,
        contentKey: contentKey,
      ),
      if (recoveryCode != null)
        await _wrapContentKeyV3(
          header: header,
          slotType: 'recovery',
          slotSecret: recoveryCode,
          contentKey: contentKey,
        ),
    ];
    return EncryptedBackupBlob(
      version: 3,
      salt: const [],
      nonce: nonce,
      cipherText: box.cipherText,
      mac: box.mac.bytes,
      keySlots: slots,
      header: header,
    );
  }

  /// Create v3 key slots wrapping an existing content key (used by enable(),
  /// which has the passphrase). Slots are stored and reused by passphrase-less
  /// [encryptEnvelopeV3WithContentKey] backups.
  Future<List<BackupKeySlot>> createV3KeySlots({
    required List<int> contentKey,
    required String passphrase,
    String? recoveryCode,
  }) async {
    final header = defaultV3Header(0); // schemaVersion is not part of slot AAD
    return [
      await _wrapContentKeyV3(
        header: header,
        slotType: 'password',
        slotSecret: passphrase,
        contentKey: contentKey,
      ),
      if (recoveryCode != null)
        await _wrapContentKeyV3(
          header: header,
          slotType: 'recovery',
          slotSecret: recoveryCode,
          contentKey: contentKey,
        ),
    ];
  }

  /// Encrypt a v3 envelope from a PRE-EXISTING content key + PRE-MADE slots — the
  /// passphrase-less path a background backup uses (enable() derived the slots).
  Future<EncryptedBackupBlob> encryptEnvelopeV3WithContentKey({
    required Map<String, dynamic> json,
    required int schemaVersion,
    required List<int> contentKey,
    required List<BackupKeySlot> keySlots,
  }) async {
    final header = defaultV3Header(schemaVersion);
    final nonce = randomBytes(BackupEnvelopeLimits.nonceLen);
    final box = await _cipher.encrypt(
      utf8.encode(jsonEncode(json)),
      secretKey: SecretKey(contentKey),
      nonce: nonce,
      aad: header.aad(),
    );
    return EncryptedBackupBlob(
      version: 3,
      salt: const [],
      nonce: nonce,
      cipherText: box.cipherText,
      mac: box.mac.bytes,
      keySlots: keySlots,
      header: header,
    );
  }

  /// Decrypt any supported envelope. v3 verifies the authenticated header + slot
  /// AAD; v1/v2 fall back to the legacy path. [secret] is the user's passphrase
  /// OR recovery code (tried against each slot with its own transform). Throws a
  /// typed [BackupEnvelopeException] — never a raw crypto exception.
  Future<Map<String, dynamic>> decryptEnvelope({
    required EncryptedBackupBlob blob,
    required String secret,
  }) async {
    if (blob.version < 3 || blob.header == null) {
      try {
        return await decryptJson(blob: blob, passphrase: secret);
      } on SecretBoxAuthenticationError {
        throw const BackupEnvelopeException(
            BackupEnvelopeErrorKind.authenticationFailed);
      }
    }
    final contentKey = await unwrapContentKeyV3(blob: blob, secret: secret);
    return decryptPayloadV3(blob: blob, contentKey: contentKey);
  }

  /// v3 — recover the content key by unwrapping whichever slot the [secret]
  /// opens (each slot's AAD binds the KDF params). Throws authenticationFailed
  /// when no slot opens (wrong secret / tamper).
  Future<List<int>> unwrapContentKeyV3({
    required EncryptedBackupBlob blob,
    required String secret,
  }) async {
    final header = blob.header!;
    for (final slot in blob.keySlots) {
      try {
        final wrappingKey = await _deriveArgon2id(
          secret: _slotSecretBytes(slot.type, secret),
          salt: slot.salt,
          header: header,
        );
        return await _cipher.decrypt(
          SecretBox(slot.cipherText, nonce: slot.nonce, mac: Mac(slot.mac)),
          secretKey: wrappingKey,
          aad: header.slotAad(slot.type),
        );
      } on SecretBoxAuthenticationError {
        // Wrong secret for this slot / tampered slot — try the next.
      }
    }
    throw const BackupEnvelopeException(
        BackupEnvelopeErrorKind.authenticationFailed);
  }

  /// v3 — decrypt the payload with a recovered content key (header bound as AAD).
  Future<Map<String, dynamic>> decryptPayloadV3({
    required EncryptedBackupBlob blob,
    required List<int> contentKey,
  }) async {
    final header = blob.header!;
    List<int> clear;
    try {
      clear = await _cipher.decrypt(
        SecretBox(blob.cipherText, nonce: blob.nonce, mac: Mac(blob.mac)),
        secretKey: SecretKey(contentKey),
        aad: header.aad(),
      );
    } on SecretBoxAuthenticationError {
      // Header/payload tamper (AAD mismatch) or corruption.
      throw const BackupEnvelopeException(
          BackupEnvelopeErrorKind.authenticationFailed);
    }
    try {
      return jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
    } catch (_) {
      throw const BackupEnvelopeException(BackupEnvelopeErrorKind.decodeFailed);
    }
  }
}
