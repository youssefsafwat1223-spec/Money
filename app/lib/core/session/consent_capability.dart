import 'package:flutter/foundation.dart';

import '../../data/db/app_database.dart';
import '../../domain/entities/supporting_entities.dart';
import 'admission_authority.dart';

/// The ONLY authority a consent write runs under (consent-security amendment).
///
/// It is issued by `AppSession` ONLY from an actual committed identity
/// publication (an explicit sign-in after its durable revocation clearance, or a
/// guarded automatic publication of a fresh SDK session), and only while the
/// actual SDK session of exactly that uid is fresh and no consent loss happened
/// since the admission began. There is no fallback: nothing is derived from the
/// authenticated status, the general local-work authority or the active database.
/// It names the uid, the admission epoch and the live database it was issued for;
/// [isCurrent] turns false, permanently, the instant that lifecycle ends (logout,
/// Remove data, another admission or account switch, auth loss, the SDK session
/// no longer matching, the scope or database changing).
///
/// It never creates anything: [canCreate] is false. Holding one authorizes a
/// consent-only local write (see [ConsentSettingsWriter]) and nothing else.
@immutable
class ConsentCapability {
  const ConsentCapability({
    required this.uid,
    required this.epoch,
    required this.database,
    required bool Function() isCurrent,
  }) : _isCurrent = isCurrent;

  final String uid;

  /// The admission epoch this capability was issued at.
  final int epoch;

  /// The exact live database of the scope it was issued for. A write against any
  /// other database is refused. Null only for UI test doubles that have none.
  final AppDatabase? database;
  final bool Function() _isCurrent;

  bool get canCreate => false;
  bool get isCurrent => _isCurrent();

  /// Throws [StaleAdmissionException] once the issuing lifecycle ended.
  void requireCurrent() {
    if (!_isCurrent()) throw const StaleAdmissionException();
  }
}

/// The consent choices a typed write applies. A null field is "unchanged": the
/// write merges these into the CURRENT stored settings, so it can never carry
/// along, or overwrite, any non-consent field of a stale entity.
@immutable
class ConsentChoices {
  const ConsentChoices({this.cloud, this.ai});

  final ConsentState? cloud;
  final ConsentState? ai;

  UserSettingsEntity applyTo(UserSettingsEntity current) => current.copyWith(
        cloudConsentState: cloud,
        aiConsentState: ai,
      );
}

/// A typed consent write: who may write it, and exactly what.
@immutable
class ConsentWrite {
  const ConsentWrite(this.capability, this.choices);

  final ConsentCapability capability;
  final ConsentChoices choices;
}

/// The typed repository operation behind every consent decision. Unlike the
/// generic settings save it takes no caller-supplied entity or callback: the
/// implementation checks the capability, the database and the replica owner
/// INSIDE its transaction, merges only the consent choices into the stored row,
/// and rolls the whole transaction back (settings and outbox) if the capability
/// ends before its final synchronous check. After that check COMMIT may still
/// land: a choice authorized while current is a legitimate local persistence and
/// is never claimed to be rolled back. It returns the row as persisted.
abstract class ConsentSettingsWriter {
  Future<UserSettingsEntity> saveConsentChoice(
    ConsentCapability capability,
    ConsentChoices choices,
  );
}
