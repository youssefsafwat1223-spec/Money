import '../../data/db/app_database.dart';
import '../../data/db/sql_value_codec.dart';
import 'outbox_failure.dart';

/// A-2 (G5/G18): shared owner-identity rules for the ledger and planning
/// outboxes.
///
/// TWO identities exist and must never be confused:
///  - the LOCAL DATA OWNER — the uid AppSession admitted as owner of this local
///    database (its owner marker). Outbox rows are stamped with it.
///  - the AUTHENTICATED uid — whoever is signed in right now. The push sends as
///    this identity, so it may only send rows recorded for it.

/// A coalesce target: a PENDING row, or a row parked by the A-2 self-healing
/// layer (never in flight, so edits may safely fold into it).
const String kOutboxCoalescibleSql =
    "(status = 'pending' OR (status = 'parked' AND "
    "COALESCE(failure_class, '') IN $kOutboxSelfHealingParkReasonsSql))";

/// D-9: SQL predicate restricting a coalesce target to rows recorded for the
/// SAME owner. An edit never folds into a row owned by a different uid (that
/// would carry this owner's payload under another owner's identity). A legacy
/// NULL-owner row stays foldable — the reconcile rule stamps it with the
/// verified current uid.
String outboxOwnerMatchSql(String? ownerUid) => ownerUid == null
    ? 'owner_uid IS NULL'
    : '(owner_uid IS NULL OR owner_uid = ${sqlString(ownerUid)})';

/// The identity a new outbox row is recorded for.
typedef OutboxIntent = ({String? ownerUid});

Future<String?> _safeUid(Future<String?> Function() read) async {
  try {
    final uid = await read();
    return (uid == null || uid.isEmpty) ? null : uid;
  } catch (_) {
    return null;
  }
}

/// Resolves the owner to stamp on a new row, or null when NO sync intent may be
/// recorded.
///
/// A local owner uid → record for it (even if the live session is momentarily
/// absent; the push still requires a session). No owner but a live session →
/// record with an UNSTAMPED (NULL) owner, stamped lazily at push time only when
/// ownership is verified. Neither → a true guest / local-only identity: no sync
/// intent, exactly as before A-2.
Future<OutboxIntent?> resolveOutboxIntent(
  Future<String?> Function() getOwnerUid,
  Future<String?> Function() getAuthUserId,
) async {
  final owner = await _safeUid(getOwnerUid);
  if (owner != null) return (ownerUid: owner);
  final auth = await _safeUid(getAuthUserId);
  if (auth == null) return null;
  return (ownerUid: null);
}

/// Whether local-data ownership for [currentUid] is verified `owned`: the owner
/// marker reads back EQUAL to the authenticated uid.
Future<bool> isOutboxOwnerVerified(
  Future<String?> Function() getOwnerUid,
  String currentUid,
) async =>
    await _safeUid(getOwnerUid) == currentUid;

/// Enforces "a row is only sent by the identity it was recorded for" on [table]:
///  1. PENDING rows recorded for another owner -> parked `owner_mismatch`.
///  2. Legacy NULL-owner rows -> stamped with [currentUid] ONLY when
///     [ownershipVerified]; otherwise PENDING ones are parked `owner_unverified`.
///  3. Rows parked for an owner reason whose owner is [currentUid] -> pending
///     again (the owner signed back in / ownership got verified).
/// Parked rows are never deleted and never sent.
Future<void> reconcileOutboxOwnership({
  required AppDatabase db,
  required String table,
  required String currentUid,
  required bool ownershipVerified,
}) async {
  final now = dateTimeToSql(DateTime.now().toUtc());
  final uid = sqlString(currentUid);
  await db.transaction(() async {
    await db.customStatement('''
      UPDATE $table
      SET status = 'parked', failure_class = '$kParkOwnerMismatch',
          next_retry_at = NULL, updated_at = ${sqlString(now)}
      WHERE status = 'pending' AND owner_uid IS NOT NULL AND owner_uid != $uid;
    ''');
    if (ownershipVerified) {
      await db.customStatement('''
        UPDATE $table SET owner_uid = $uid WHERE owner_uid IS NULL;
      ''');
    } else {
      await db.customStatement('''
        UPDATE $table
        SET status = 'parked', failure_class = '$kParkOwnerUnverified',
            next_retry_at = NULL, updated_at = ${sqlString(now)}
        WHERE status = 'pending' AND owner_uid IS NULL;
      ''');
    }
    await db.customStatement('''
      UPDATE $table
      SET status = 'pending', failure_class = NULL, next_retry_at = NULL,
          updated_at = ${sqlString(now)}
      WHERE status = 'parked'
        AND failure_class IN ('$kParkOwnerMismatch', '$kParkOwnerUnverified')
        AND owner_uid = $uid;
    ''');
  });
}
