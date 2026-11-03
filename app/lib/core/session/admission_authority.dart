import 'package:flutter/foundation.dart';

import '../../data/db/database_access_broker.dart' show DatabaseOpenReservation;

/// F2 — the authority to admit one uid, handed down the whole admission chain
/// (explicit auth attempt -> ownership resolution -> owner marker/generation
/// writes -> replica admission -> scope activation -> replica open/create -> key
/// creation -> scope publication).
///
/// It is a capability bound to a uid and to the session's admission [epoch].
/// Accepting an explicit "Remove data", a sign-out or an explicit account switch
/// advances the epoch SYNCHRONOUSLY (Remove data also closes admission), so every
/// authority captured before it reports [isCurrent] == false from that instant,
/// whatever continuation still holds it. Every layer of the chain re-checks it for
/// the uid it was asked to act on BEFORE its side effect ([requireFor]); a stale
/// callback, or one holding another uid's authority, therefore fails before it
/// writes, opens or creates anything.
///
/// [canCreate] separates "open the replica that exists" (automatic paths: auth
/// events, resume revalidation, rebootstrap re-opens) from "create a fresh
/// replica" (an explicit, current authentication attempt, or a rebootstrap's
/// maintenance authority). A missing registry entry, database or key is never
/// by itself permission to create.
@immutable
class AdmissionAuthority {
  const AdmissionAuthority(
    this.uid,
    this._isCurrent, {
    this.canCreate = false,
    this.epoch = 0,
    this.openReservation,
    this.causeAuthority,
  });

  /// An always-current authority for tests that exercise storage in isolation.
  @visibleForTesting
  const AdmissionAuthority.forTest(this.uid, {this.canCreate = true})
      : _isCurrent = _always,
        epoch = 0,
        openReservation = null,
        causeAuthority = null;

  static bool _always() => true;

  final String uid;
  final bool canCreate;

  /// The admission epoch this authority was issued at.
  final int epoch;
  final bool Function() _isCurrent;

  /// O: the private single-opener reservation minted for exactly this
  /// admission's open (null when no coordinator is configured). It is
  /// bookkeeping only: it adds no authority this authority did not carry.
  final DatabaseOpenReservation? openReservation;

  /// ASR §11.2: the op this admission is the adoption of (null otherwise). The
  /// causes of the scope it opens belong to that op. Bookkeeping only: it adds
  /// no authority.
  final Object? causeAuthority;

  /// This same authority (same uid, epoch, currency) carrying [reservation].
  AdmissionAuthority withOpenReservation(DatabaseOpenReservation reservation) =>
      AdmissionAuthority(uid, _isCurrent,
          canCreate: canCreate,
          epoch: epoch,
          openReservation: reservation,
          causeAuthority: causeAuthority);

  /// This same authority carrying [authority] as its cause authority.
  AdmissionAuthority withCauseAuthority(Object authority) =>
      AdmissionAuthority(uid, _isCurrent,
          canCreate: canCreate,
          epoch: epoch,
          openReservation: openReservation,
          causeAuthority: authority);

  bool get isCurrent => _isCurrent();

  /// Throws [StaleAdmissionException] when the authority was revoked.
  void requireCurrent() {
    if (!_isCurrent()) throw const StaleAdmissionException();
  }

  /// Throws [StaleAdmissionException] unless this authority belongs to [uid] AND
  /// is still current. The check every storage layer makes for the uid it acts on.
  void requireFor(String uid) {
    if (uid != this.uid || !_isCurrent()) throw const StaleAdmissionException();
  }
}

/// An authentication attempt, captured BEFORE the provider is awaited. Only a
/// successful attempt that is still current when it completes may authorize
/// (re)creating a removed uid's data.
@immutable
class AuthAttempt {
  const AuthAttempt(this.epoch, [this.intent = 0]);
  final int epoch;

  /// ASR §4.1: the AuthCoordinator intent registered at the attempt start (0
  /// without a coordinator). The explicit exchange and commit carry it.
  final int intent;
}

/// The authority was revoked (Remove data accepted, or admission closed) before
/// the guarded side effect. Nothing was written, opened or created.
class StaleAdmissionException implements Exception {
  const StaleAdmissionException();
  @override
  String toString() => 'StaleAdmissionException: admission authority revoked.';
}
