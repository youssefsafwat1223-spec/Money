import 'package:flutter/foundation.dart';

import '../../core/session/admission_authority.dart';

/// F2 — a database or key would have to be CREATED, but the caller holds no
/// authority to create (a cold launch, a secondary/background open, a rebootstrap
/// re-open, or an authority revoked by Remove data). Nothing was written. A
/// missing file, key or registry entry is never permission to create. Carries no
/// path, uid or key.
class DatabaseCreationNotAuthorizedException implements Exception {
  const DatabaseCreationNotAuthorizedException();

  @override
  String toString() => 'DatabaseCreationNotAuthorizedException: refused to '
      'create a database or key without admission authority.';
}

/// F2 — what a storage layer may CREATE (a database file, its directory, its key).
///
/// It is handed down the whole chain (ReplicaStore -> AppDatabase -> key store) so
/// every layer verifies, BEFORE its own side effect, that the creation is still
/// authorized: an [AdmissionAuthority] bound to the uid being created for, current
/// (not revoked by Remove data, sign-out or an account switch) and allowed to
/// create. A plain boolean could not be revoked mid-flight.
///
/// * [CreationPolicy.unrestricted] — pre-F2 behaviour for storage that is not a
///   per-account replica (the legacy shared database, in-memory databases, tests
///   of the storage layer in isolation).
/// * [CreationPolicy.denied] — open the EXISTING database only. Launch, secondary
///   (background isolate) and rebootstrap re-opens.
/// * [CreationPolicy.authorized] — create for exactly one uid, while its
///   authority stays current.
@immutable
class CreationPolicy {
  const CreationPolicy.unrestricted()
      : _authority = null,
        _uid = null,
        _kind = _Kind.unrestricted;

  const CreationPolicy.denied({AdmissionAuthority? authority, String? uid})
      : _authority = authority,
        _uid = uid,
        _kind = _Kind.denied;

  const CreationPolicy.authorized(AdmissionAuthority authority, String uid)
      : _authority = authority,
        _uid = uid,
        _kind = _Kind.authorized;

  final AdmissionAuthority? _authority;
  final String? _uid;
  final _Kind _kind;

  /// False for [CreationPolicy.denied]: the caller may only open what exists.
  bool get mayEverCreate => _kind != _Kind.denied;

  /// Throws, having changed nothing, unless creating is permitted RIGHT NOW:
  /// [DatabaseCreationNotAuthorizedException] when it never was,
  /// [StaleAdmissionException] when the authority belongs to another uid or was
  /// revoked.
  void requireCurrent() {
    final authority = _authority;
    if (authority != null) authority.requireFor(_uid!);
  }

  void requireMayCreate() {
    requireCurrent();
    switch (_kind) {
      case _Kind.unrestricted:
        return;
      case _Kind.denied:
        throw const DatabaseCreationNotAuthorizedException();
      case _Kind.authorized:
        final authority = _authority!;
        authority.requireFor(_uid!);
        if (!authority.canCreate) {
          throw const DatabaseCreationNotAuthorizedException();
        }
    }
  }
}

enum _Kind { unrestricted, denied, authorized }
