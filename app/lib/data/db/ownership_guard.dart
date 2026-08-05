import 'package:flutter_secure_storage/flutter_secure_storage.dart';

// MALI-069n §Blocker-3 (Batch-4 closure) — cross-isolate ownership invalidation
// for background secondary jobs. A background isolate does NOT share the main
// owner object in memory, so it re-reads the Phase-2 admission owner UID (stored
// in flutter_secure_storage → visible to every isolate/process) rather than
// inventing a second identity system. A job captures the owner token when it is
// created and re-checks it before the Drift commit and the native acknowledgement;
// a sign-out / destructive wipe / ownership change clears or rewrites the owner
// UID, so the old-user job aborts WITHOUT committing or acknowledging, and a new
// user can never inherit the previous user's pending operation.
class OwnershipGuard {
  OwnershipGuard({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  // The exact key Phase-2 (AppSession) writes the admitted local-data owner to.
  static const String _kOwnerUid = 'local_data_owner_uid';

  /// Capture the current owner token at job creation. May be null before the
  /// first admission.
  Future<String?> capture() => _storage.read(key: _kOwnerUid);

  /// True only if the owner has NOT changed since [token] was captured. A
  /// sign-out / wipe / ownership change makes this false — the caller must then
  /// abort before committing or acknowledging.
  Future<bool> stillOwnedBy(String? token) async {
    final current = await _storage.read(key: _kOwnerUid);
    return current == token;
  }

  /// Run [commit] only if ownership is unchanged since [token]; otherwise skip it
  /// and return null (the old-user job aborts cleanly). Callers re-check right
  /// before the commit AND before any native acknowledgement.
  Future<T?> guardCommit<T>(String? token, Future<T> Function() commit) async {
    if (!await stillOwnedBy(token)) return null;
    return commit();
  }
}
