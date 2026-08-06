import 'package:flutter_secure_storage/flutter_secure_storage.dart';

// MALI-069n §Blocker-1 (Batch-4 closure #3) — cross-isolate ADMISSION-GENERATION
// invalidation for background secondary jobs.
//
// A UID alone cannot invalidate work from a PREVIOUS session of the SAME user
// (A → sign-out → A, or A → B → A): a stale job still carrying UID A would be
// accepted in the new admission lifecycle. So a background job is bound to an
// admission GENERATION as well as the owner UID. The generation is a
// cryptographically-random nonce that Phase-2 admission (`AppSession`) rotates on
// every genuine admission and invalidates before sign-out / wipe / ownership
// change — so it rotates EVEN WHEN THE SAME UID SIGNS IN AGAIN. Both values live in
// flutter_secure_storage (Keychain/Keystore), readable by every isolate/process,
// so a background isolate that does not share the owner object in memory can still
// validate. This REUSES and extends the Phase-2 admission state rather than
// introducing a second identity system. Neither field is a secret and neither
// carries any financial data.
//
// A job captures the token at creation and re-validates it at every boundary:
//   1. before acquiring the database lease;
//   2. before opening the secondary connection;
//   3. immediately before the Drift commit;
//   4. immediately before the native acknowledgement;
//   5. before publishing any notification or other side effect.
// A mismatch aborts with [StaleOwnershipException] — the job must NOT commit,
// acknowledge, notify, or retry under the new admission.

/// Thrown / signalled when a background job's captured admission no longer matches
/// the current admission (sign-out, wipe, ownership change, or same-UID re-login).
class StaleOwnershipException implements Exception {
  const StaleOwnershipException();
  @override
  String toString() => 'StaleOwnershipException';
}

/// A captured admission identity: the owner UID plus the admission generation. Two
/// tokens are equal only when BOTH match. Carries no secret and no financial data.
class AdmissionToken {
  const AdmissionToken({required this.ownerUid, required this.generation});

  final String? ownerUid;
  final String? generation;

  bool matches(AdmissionToken other) =>
      ownerUid == other.ownerUid && generation == other.generation;

  @override
  bool operator ==(Object other) =>
      other is AdmissionToken &&
      other.ownerUid == ownerUid &&
      other.generation == generation;

  @override
  int get hashCode => Object.hash(ownerUid, generation);

  /// Privacy-safe: reveals only whether the fields are present, never their values.
  @override
  String toString() =>
      'AdmissionToken(uid:${ownerUid == null ? 'none' : 'set'}, '
      'gen:${generation == null ? 'none' : 'set'})';
}

class OwnershipGuard {
  OwnershipGuard({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  // The exact keys Phase-2 (AppSession) writes admission state to.
  static const String _kOwnerUid = 'local_data_owner_uid';
  static const String _kOwnerGeneration = 'local_data_owner_generation';

  /// Capture the current admission token at job creation.
  Future<AdmissionToken> capture() async {
    final uid = await _storage.read(key: _kOwnerUid);
    final gen = await _storage.read(key: _kOwnerGeneration);
    return AdmissionToken(ownerUid: uid, generation: gen);
  }

  /// True only if the current admission still matches [token] — same owner UID AND
  /// same generation. A sign-out / wipe / ownership change / same-UID re-login all
  /// make this false, so the caller must abort before committing or acknowledging.
  Future<bool> isCurrent(AdmissionToken token) async {
    final current = await capture();
    return current.matches(token);
  }

  /// Run [commit] only if the admission is unchanged since [token]; otherwise skip
  /// it and return null (the stale job aborts cleanly without committing). Callers
  /// re-check right before the commit AND before any native acknowledgement.
  Future<T?> guardCommit<T>(AdmissionToken token, Future<T> Function() commit) async {
    if (!await isCurrent(token)) return null;
    return commit();
  }
}
