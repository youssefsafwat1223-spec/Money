/// The device's parser-authority epoch.
///
/// THE PROBLEM THIS SOLVES
/// Revocation reaches a device only when it actually fetches parsers, and
/// `syncAll` fetches a category only when `serverVersion > localVersion`. That
/// is fine for a FUTURE revocation — demotion bumps the version through
/// `trg_parsers_version`, so the device is told to fetch. It is not fine for an
/// install that is ALREADY at the current version: it never re-fetches, so
/// rules the previous release activated from the bundle keep money authority
/// indefinitely, with no server event that would dislodge them.
///
/// THE CONTRACT
/// The epoch names the authority rules this build understands. When the stored
/// epoch is older than [kParserAuthorityEpoch] the device must, exactly once:
///
///   1. deactivate every local parser BEFORE any of them can be consulted, and
///   2. force ONE full parser fetch regardless of version comparison, which
///      succeeds only against a fully verified authoritative snapshot.
///
/// The epoch is persisted ONLY after that snapshot is applied. So an offline,
/// truncated, malformed or stale response leaves the epoch stale, the parsers
/// inactive, and the refresh pending for the next launch — fail-closed, with
/// the engine's own heuristics carrying parsing in the meantime, which is
/// exactly what happens in production today where no parser is servable.
///
/// It is NOT "deactivate on every startup": once the epoch is current the
/// device returns to ordinary version-driven sync, and a re-validated rule is
/// reactivated by [RemoteParsersDao.applyAuthoritativeServableSet].
library;

import '../db/app_database.dart';
import 'catalog_daos.dart';

/// Bump when the authority contract changes in a way that must invalidate
/// whatever a previous release left active.
///
/// 1 — implicit; releases that seeded the bundled rules ACTIVE with no
///     validation metadata, and had no revocation path at all.
/// 2 — bundle seeds inactive; serving requires a verified snapshot.
const int kParserAuthorityEpoch = 2;

/// Stored in `catalog_metadata` under this pseudo-category, so the epoch needs
/// no schema change and travels with the rest of the catalog bookkeeping.
const String kParserAuthorityEpochKey = '_parser_authority_epoch';

/// What the device must do about parser authority before trusting any rule.
enum ParserAuthorityAction {
  /// The stored epoch matches; ordinary version-driven sync applies.
  upToDate,

  /// The stored epoch is older: legacy rules have been deactivated and a full
  /// authoritative refresh is required before any parser may serve again.
  refreshRequired,
}

class ParserAuthority {
  const ParserAuthority(this._parsers, this._metadata, this._db);

  final RemoteParsersDao _parsers;
  final CatalogMetadataDao _metadata;
  final AppDatabase _db;

  Future<int> storedEpoch() async {
    final row = await _metadata.getVersion(kParserAuthorityEpochKey);
    return row?.localVersion ?? 0;
  }

  /// Called before parsers are used or synced.
  ///
  /// Deactivating first is the whole point: if the process dies immediately
  /// afterwards, the device is left with NO active parser rather than legacy
  /// ones, and the refresh is retried on the next launch because the epoch was
  /// not advanced.
  Future<ParserAuthorityAction> reconcile() async {
    // ATOMIC. Two syncs can overlap (a cold-start force and a resume). Reading
    // the epoch, then awaiting, then deactivating outside a transaction lets
    // the second call wipe the set the first just activated — and if its own
    // fetch then fails, the device is left with a CURRENT epoch and zero active
    // parsers, which no later launch would force-refresh.
    return _db.transaction(() async {
      if (await storedEpoch() >= kParserAuthorityEpoch) {
        return ParserAuthorityAction.upToDate;
      }
      await _parsers.deactivateAll();
      return ParserAuthorityAction.refreshRequired;
    });
  }

  /// Records that a verified authoritative snapshot has been applied.
  ///
  /// Only the sync path calls this, and only after
  /// `_authoritativeServableIdsImpl` accepted the snapshot — so the epoch can
  /// never advance on an offline, truncated, malformed or stale response.
  Future<void> markRefreshed() async {
    await _metadata.upsertVersion(
      kParserAuthorityEpochKey,
      kParserAuthorityEpoch,
      kParserAuthorityEpoch,
    );
  }
}
