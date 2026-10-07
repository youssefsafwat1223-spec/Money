import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/security/secure_storage_options.dart';
import 'app_database.dart';
import 'database_key_store.dart';
import 'replica_location.dart';

/// WP-3a — the per-UID encrypted replica CORE (storage layer only).
///
/// One SQLCipher file and one key per authenticated uid:
///
///     <AppSupport>/replicas/<uidHash>/qirsh.sqlite  (+ -wal/-shm and every
///                                                    maintenance/lease/liveness
///                                                    sidecar, same directory)
///     secure storage: qirsh.db_key.<uidHash>   (first_unlock_this_device)
///                     qirsh.replicas.v1         (the registry below)
///                     qirsh.device_salt         (HMAC salt, random, per device)
///
/// `uidHash = hex(HMAC-SHA256(deviceSalt, uid))` truncated to 128 bits, so the
/// file system never reveals the raw uid.
///
/// The registry is a HINT (state, timestamps). Ownership is decided by
/// `replica_meta.owner_uid` inside the file, asserted on every open, failing
/// CLOSED on any mismatch. The session/account wiring, sign-out and Remove-data
/// UI are WP-3b; this class is only the storage API they call.

/// Registry state of one replica.
enum ReplicaState { active, locked, migrating, quarantined }

/// WP-7 — the manifest §4.10 durable rebootstrap phase, in execution order. A
/// crash at any phase resumes from the registry marker. Wire names are the
/// manifest's (`frozen`, `extracted`, `fresh_bootstrapped`, ...).
enum RebootstrapPhase {
  frozen('frozen'),
  extracted('extracted'),
  freshBootstrapped('fresh_bootstrapped'),
  receiptsRecovered('receipts_recovered'),
  pulledMerged('pulled_merged'),
  outboxRecovered('outbox_recovered'),
  conflictsMerged('conflicts_merged'),
  swapped('swapped'),
  captureResumed('capture_resumed');

  const RebootstrapPhase(this.wire);
  final String wire;

  static RebootstrapPhase fromWire(String w) =>
      values.firstWhere((p) => p.wire == w);
}

/// The in-progress rebootstrap of one replica (counts and names only, never
/// content). Absent once `capture_resumed` has been reached.
class RebootstrapMarker {
  const RebootstrapMarker({
    required this.phase,
    required this.reason,
    required this.startedAt,
    this.swapping = false,
  });

  final RebootstrapPhase phase;

  /// The swap's file moves have begun (set before the first one): a resume must
  /// finish the swap, never rebuild or reopen the replica names mid-move.
  final bool swapping;

  /// `user_sync_state.epoch_reason` that triggered it (`purge`, `reset`,
  /// `restore`, ...). `purge` never replays anything.
  final String reason;
  final DateTime startedAt;

  Map<String, Object?> toJson() => {
        'phase': phase.wire,
        'reason': reason,
        'startedAt': startedAt.toUtc().toIso8601String(),
        if (swapping) 'swapping': true,
      };

  static RebootstrapMarker fromJson(Map<String, Object?> j) => RebootstrapMarker(
        phase: RebootstrapPhase.fromWire(j['phase']! as String),
        reason: j['reason']! as String,
        startedAt: DateTime.parse(j['startedAt']! as String),
        swapping: j['swapping'] == true,
      );
}

/// One registry entry (uidHash → this).
class ReplicaEntry {
  const ReplicaEntry({
    required this.uidHash,
    required this.createdAt,
    required this.lastOpenedAt,
    required this.schemaVersion,
    required this.epoch,
    required this.state,
    this.adoptPending = false,
    this.legacyAdoptedAt,
    this.rebootstrap,
    this.retiredAt,
  });

  final String uidHash;
  final DateTime createdAt;
  final DateTime lastOpenedAt;
  final int schemaVersion;
  final int epoch;
  final ReplicaState state;

  /// Legacy adoption into this replica has started and the legacy file has not
  /// yet been renamed to `.adopted`. Drives crash recovery.
  final bool adoptPending;

  /// When the legacy file was renamed to `.adopted`; the 7-day P2 rollback
  /// grace is measured from here. Null once purged (or never adopted).
  final DateTime? legacyAdoptedAt;

  /// WP-7: the rebootstrap in progress, if any (see [RebootstrapPhase]).
  final RebootstrapMarker? rebootstrap;

  /// WP-7: when a swapped rebootstrap retired the previous replica to
  /// `<hash>.old`; the 14-day retention (manifest §13) is measured from here.
  final DateTime? retiredAt;

  ReplicaEntry copyWith({
    DateTime? lastOpenedAt,
    int? schemaVersion,
    int? epoch,
    ReplicaState? state,
    bool? adoptPending,
    DateTime? legacyAdoptedAt,
    bool clearLegacyAdoptedAt = false,
    RebootstrapMarker? rebootstrap,
    bool clearRebootstrap = false,
    DateTime? retiredAt,
    bool clearRetiredAt = false,
  }) =>
      ReplicaEntry(
        uidHash: uidHash,
        createdAt: createdAt,
        lastOpenedAt: lastOpenedAt ?? this.lastOpenedAt,
        schemaVersion: schemaVersion ?? this.schemaVersion,
        epoch: epoch ?? this.epoch,
        state: state ?? this.state,
        adoptPending: adoptPending ?? this.adoptPending,
        legacyAdoptedAt: clearLegacyAdoptedAt
            ? null
            : (legacyAdoptedAt ?? this.legacyAdoptedAt),
        rebootstrap:
            clearRebootstrap ? null : (rebootstrap ?? this.rebootstrap),
        retiredAt: clearRetiredAt ? null : (retiredAt ?? this.retiredAt),
      );

  Map<String, Object?> toJson() => {
        'createdAt': createdAt.toUtc().toIso8601String(),
        'lastOpenedAt': lastOpenedAt.toUtc().toIso8601String(),
        'schemaVersion': schemaVersion,
        'epoch': epoch,
        'state': state.name,
        if (adoptPending) 'adoptPending': true,
        if (legacyAdoptedAt != null)
          'legacyAdoptedAt': legacyAdoptedAt!.toUtc().toIso8601String(),
        if (rebootstrap != null) 'rebootstrap': rebootstrap!.toJson(),
        if (retiredAt != null) 'retiredAt': retiredAt!.toUtc().toIso8601String(),
      };

  static ReplicaEntry fromJson(String uidHash, Map<String, Object?> j) =>
      ReplicaEntry(
        uidHash: uidHash,
        createdAt: DateTime.parse(j['createdAt']! as String),
        lastOpenedAt: DateTime.parse(j['lastOpenedAt']! as String),
        schemaVersion: j['schemaVersion']! as int,
        epoch: j['epoch']! as int,
        state: ReplicaState.values.byName(j['state']! as String),
        adoptPending: j['adoptPending'] == true,
        legacyAdoptedAt: j['legacyAdoptedAt'] == null
            ? null
            : DateTime.parse(j['legacyAdoptedAt']! as String),
        rebootstrap: j['rebootstrap'] == null
            ? null
            : RebootstrapMarker.fromJson(
                (j['rebootstrap']! as Map).cast<String, Object?>()),
        retiredAt: j['retiredAt'] == null
            ? null
            : DateTime.parse(j['retiredAt']! as String),
      );
}

/// The file's `replica_meta.owner_uid` is missing or is not the requested uid.
/// Fails closed; carries no uid.
class ReplicaOwnershipException implements Exception {
  const ReplicaOwnershipException();
  @override
  String toString() => 'ReplicaOwnershipException: replica owner mismatch.';
}

/// The replica exists but is not openable in its current registry state
/// (`locked`: signed out, SYNC-Q3; `migrating`; `quarantined`).
class ReplicaUnavailableException implements Exception {
  const ReplicaUnavailableException(this.state);
  final ReplicaState state;
  @override
  String toString() => 'ReplicaUnavailableException(${state.name})';
}

/// Result of [ReplicaStore.adoptLegacyIfPresent].
enum AdoptionOutcome {
  /// No legacy file, nothing to do.
  none,

  /// The legacy DB was copied into the owner's replica and renamed `.adopted`.
  adopted,

  /// No real owner marker: the legacy file was moved to `replicas/_quarantine/`.
  quarantined,

  /// A step failed (or the process died earlier and this launch could not
  /// finish). The legacy file is still in place and still in use; the registry
  /// state `migrating` makes the next launch retry.
  failed,

  /// The owner already has an active replica AND a legacy file reappeared (a
  /// downgrade-then-upgrade). Nothing is overwritten; WP-3b decides.
  legacyLeftover,
}

/// Fixed order of the adoption steps; a test hook may stop the process after any
/// of them.
const List<String> kAdoptionSteps = [
  'beforeCopy',
  'afterCopy',
  'afterKeyCopy',
  'afterProbe',
  'afterReplicaMeta',
  'afterRegistryActive',
  'beforeRename',
  'afterRename',
];

/// Fixed order of the swap steps (WP-7); a test hook may stop the process after
/// any of them.
const List<String> kSwapSteps = [
  'swap:beforeOldMoved',
  'swap:afterOldMoved',
  'swap:afterOldKey',
  'swap:afterFreshMoved',
  'swap:afterFreshKey',
];

typedef ReplicaOpener = Future<AppDatabase> Function({
  ReplicaLocation? location,
  bool runMigrations,
});

class ReplicaStore {
  ReplicaStore({
    FlutterSecureStorage? storage,
    String? appSupportDirectory,
    DateTime Function()? now,
    ReplicaOpener? opener,
    Future<String?> Function()? readOwnerMarker,
    Future<void> Function(String step)? debugAfterAdoptionStep,
  })  : _storage = storage ?? SecureStorageOptions.storage,
        _appSupport = appSupportDirectory,
        _now = now ?? DateTime.now,
        _opener = opener ?? AppDatabase.open,
        _readOwnerMarker = readOwnerMarker,
        _debugStep = debugAfterAdoptionStep;

  static const String registryKey = 'qirsh.replicas.v1';
  static const String saltKey = 'qirsh.device_salt';
  static const String keyNamePrefix = 'qirsh.db_key.';
  static const String dbFileName = 'qirsh.sqlite';

  /// The AppSession owner marker (`core/session/app_session.dart`). Read-only here.
  static const String ownerMarkerKey = 'local_data_owner_uid';
  static const String _transitionPrefix = 'owner-transition-pending:';

  /// P2 rollback grace for the `.adopted` legacy file (manifest §13).
  static const Duration adoptedGrace = Duration(days: 7);

  /// WP-7: how long a swapped rebootstrap keeps the replica it retired
  /// (manifest §13).
  static const Duration retiredReplicaRetention = Duration(days: 14);

  /// Directory/key suffixes of the side-by-side rebootstrap: `.rb` is the fresh
  /// replica being built, `.old` the retired one.
  static const String stagingSuffix = '.rb';
  static const String retiredSuffix = '.old';

  final FlutterSecureStorage _storage;
  final String? _appSupport;
  final DateTime Function() _now;
  final ReplicaOpener _opener;
  final Future<String?> Function()? _readOwnerMarker;
  final Future<void> Function(String step)? _debugStep;

  final Map<String, AppDatabase> _open = {};
  final Map<String, AppDatabase> _staging = {};
  Future<void> _tail = Future.value();
  Future<String>? _saltFuture;

  // ------------------------------------------------------------------ paths

  Future<String> _support() async =>
      _appSupport ?? (await getApplicationSupportDirectory()).path;

  Future<String> _replicasRoot() async => p.join(await _support(), 'replicas');

  Future<ReplicaLocation> _location(String hash) async => ReplicaLocation(
        directory: p.join(await _replicasRoot(), hash),
        dbFileName: dbFileName,
        keyName: '$keyNamePrefix$hash',
      );

  Future<ReplicaLocation> _legacyLocation() async => ReplicaLocation(
        directory: await _support(),
        dbFileName: ReplicaLocation.legacyDbFileName,
        keyName: ReplicaLocation.legacyKeyName,
      );

  Future<Directory> _quarantineRoot() async =>
      Directory(p.join(await _replicasRoot(), '_quarantine'));

  // ---------------------------------------------------------------- uid hash

  Future<String> _deviceSalt() => _saltFuture ??= () async {
        final existing = await _storage.read(key: saltKey);
        if (existing != null && existing.isNotEmpty) return existing;
        final rng = Random.secure();
        final salt = List<int>.generate(32, (_) => rng.nextInt(256))
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
        await _storage.write(key: saltKey, value: salt);
        return salt;
      }();

  /// `hex(HMAC-SHA256(deviceSalt, uid))`, truncated to 128 bits.
  Future<String> uidHash(String uid) async {
    final mac = Hmac(sha256, utf8.encode(await _deviceSalt()));
    return mac.convert(utf8.encode(uid)).toString().substring(0, 32);
  }

  // ---------------------------------------------------------------- registry

  Future<Map<String, ReplicaEntry>> _readRegistry() async {
    final raw = await _storage.read(key: registryKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final json = jsonDecode(raw) as Map<String, Object?>;
      return {
        for (final e in json.entries)
          e.key: ReplicaEntry.fromJson(
              e.key, (e.value! as Map).cast<String, Object?>()),
      };
    } catch (_) {
      // The registry is a hint, never authority: an unreadable one is empty and
      // is rebuilt from the replicas themselves as they are opened.
      return {};
    }
  }

  Future<void> _writeRegistry(Map<String, ReplicaEntry> m) => _storage.write(
        key: registryKey,
        value: jsonEncode({for (final e in m.entries) e.key: e.value.toJson()}),
      );

  /// Serialised read-modify-write of one entry (null result removes it).
  Future<void> _mutate(
      String hash, ReplicaEntry? Function(ReplicaEntry? current) f) {
    final run = _tail.then((_) async {
      final reg = await _readRegistry();
      final next = f(reg[hash]);
      if (next == null) {
        reg.remove(hash);
      } else {
        reg[hash] = next;
      }
      await _writeRegistry(reg);
    });
    _tail = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  /// Every registry entry (never ownership authority).
  Future<List<ReplicaEntry>> list() async =>
      (await _readRegistry()).values.toList();

  /// Marks the replica `locked` (signed out; refuses open) or `active`.
  /// Returns false when no entry exists.
  Future<bool> setState(String uid, ReplicaState state) async {
    final hash = await uidHash(uid);
    var found = false;
    await _mutate(hash, (c) {
      if (c == null) return null;
      found = true;
      return c.copyWith(state: state);
    });
    return found;
  }

  // -------------------------------------------------------------- open/close

  /// Opens (creating on first use) the replica of [uid].
  ///
  /// Fails closed with [ReplicaUnavailableException] for `locked`/`migrating`/
  /// `quarantined` entries (call [setState] with `active` first once the session
  /// has authenticated), and with [ReplicaOwnershipException] when the file's
  /// `replica_meta.owner_uid` is absent or not [uid]. At most one open handle per
  /// uid is kept: a second call returns the already-open database.
  Future<AppDatabase> openReplica(String uid) async {
    if (uid.isEmpty || uid.startsWith(_transitionPrefix)) {
      throw const ReplicaOwnershipException();
    }
    final hash = await uidHash(uid);
    final already = _open[hash];
    if (already != null && already.lifecycleState == DatabaseLifecycleState.open) {
      return already;
    }

    final entry = (await _readRegistry())[hash];
    if (entry != null && entry.state != ReplicaState.active) {
      throw ReplicaUnavailableException(entry.state);
    }
    final loc = await _location(hash);
    final existed = await File(loc.dbPath).exists();
    final db = await _opener(location: loc, runMigrations: true);
    try {
      final owner = await _readMeta(db);
      if (owner == null && !existed) {
        await _writeMeta(db, uid);
      } else if (owner != uid) {
        throw const ReplicaOwnershipException();
      }
      final now = _now();
      final version = await _userVersion(db);
      await _mutate(
        hash,
        (c) =>
            c?.copyWith(
                lastOpenedAt: now,
                schemaVersion: version,
                state: ReplicaState.active) ??
            ReplicaEntry(
              uidHash: hash,
              createdAt: now,
              lastOpenedAt: now,
              schemaVersion: version,
              epoch: 0,
              state: ReplicaState.active,
            ),
      );
    } catch (_) {
      await db.close();
      rethrow;
    }
    return _open[hash] = db;
  }

  /// The pre-WP-3a shared database location (for the failed-adoption fallback).
  Future<ReplicaLocation> legacyLocation() => _legacyLocation();

  /// Where [uid]'s replica lives (whether or not it exists yet).
  Future<ReplicaLocation> locationFor(String uid) async =>
      _location(await uidHash(uid));

  /// Where the signed-in account's database lives, resolved from persisted state
  /// only (the owner marker + the registry), for code that has no in-memory
  /// account scope: the background capture/notification isolates and the backup
  /// service. Null when no account is admitted or its replica is not `active`
  /// (signed out = locked, SYNC-Q3), so such callers fail closed instead of
  /// opening someone else's file. A `migrating` replica whose legacy file is
  /// still in place resolves to the legacy file (a failed adoption "leaves the
  /// legacy file in place and in use").
  Future<ReplicaLocation?> activeLocation() async {
    final marker = await _marker();
    if (marker == null || marker.isEmpty || marker.startsWith(_transitionPrefix)) {
      return null;
    }
    final hash = await uidHash(marker);
    final entry = (await _readRegistry())[hash];
    if (entry == null) return null;
    // WP-7: until `swapped` has committed no background isolate may open the
    // replica a rebootstrap is replacing (capture delivery stays disabled).
    final rb = entry.rebootstrap;
    if (rb != null && rb.phase.index < RebootstrapPhase.swapped.index) {
      return null;
    }
    if (entry.state == ReplicaState.active) return _location(hash);
    if (entry.state == ReplicaState.migrating) {
      final legacy = await _legacyLocation();
      if (await File(legacy.dbPath).exists()) return legacy;
    }
    return null;
  }

  /// Closes every open handle (replicas and fresh staging replicas) without
  /// deleting anything. Idempotent.
  Future<void> closeAll() async {
    for (final db in [..._open.values, ..._staging.values]) {
      await db.close();
    }
    _open.clear();
    _staging.clear();
  }

  /// Closes the open replica of [uid], if any. Idempotent.
  Future<void> closeReplica(String uid) async {
    final db = _open.remove(await uidHash(uid));
    await db?.close();
  }

  static Future<String?> _readMeta(AppDatabase db) async {
    final rows =
        await db.customSelect('SELECT owner_uid FROM replica_meta;').get();
    return rows.isEmpty ? null : rows.single.read<String>('owner_uid');
  }

  static Future<void> _writeMeta(AppDatabase db, String uid) async {
    final rng = Random.secure();
    final replicaId = List<int>.generate(16, (_) => rng.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    await db.customStatement(
      'INSERT INTO replica_meta(id, owner_uid, replica_id, server_epoch, '
      'created_at) VALUES (1, ?, ?, 0, ?);',
      [uid, replicaId, DateTime.now().toUtc().toIso8601String()],
    );
  }

  static Future<int> _userVersion(AppDatabase db) async =>
      (await db.customSelect('PRAGMA user_version;').getSingle())
          .read<int>('user_version');

  // ------------------------------------------------- WP-7 rebootstrap (§4.10)

  /// The rebootstrap marker of [uid]'s replica, or null when none is in progress.
  Future<RebootstrapMarker?> rebootstrapMarker(String uid) async =>
      (await _readRegistry())[await uidHash(uid)]?.rebootstrap;

  /// Every replica with a rebootstrap in progress (launch resume).
  Future<List<ReplicaEntry>> pendingRebootstraps() async => [
        for (final e in await list())
          if (e.rebootstrap != null) e,
      ];

  /// Starts a rebootstrap at `frozen` (a no-op when one is already recorded, so
  /// the original reason survives a resume). False when the uid has no registry
  /// entry.
  Future<bool> beginRebootstrap(String uid, String reason) async {
    final hash = await uidHash(uid);
    var found = false;
    await _mutate(hash, (c) {
      if (c == null) return null;
      found = true;
      if (c.rebootstrap != null) return c;
      return c.copyWith(
        rebootstrap: RebootstrapMarker(
          phase: RebootstrapPhase.frozen,
          reason: reason,
          startedAt: _now(),
        ),
      );
    });
    return found;
  }

  /// Durably advances the marker. Never moves it backwards; reaching
  /// `capture_resumed` ends the rebootstrap (the marker is removed).
  Future<void> advanceRebootstrap(String uid, RebootstrapPhase phase) async {
    final hash = await uidHash(uid);
    await _mutate(hash, (c) {
      final m = c?.rebootstrap;
      if (c == null || m == null) return c;
      if (phase == RebootstrapPhase.captureResumed) {
        return c.copyWith(clearRebootstrap: true);
      }
      if (phase.index <= m.phase.index) return c;
      return c.copyWith(
        rebootstrap: RebootstrapMarker(
            phase: phase,
            reason: m.reason,
            startedAt: m.startedAt,
            swapping: m.swapping),
      );
    });
  }

  /// Opens (creating on first use) the FRESH replica a rebootstrap builds next to
  /// the live one: `replicas/<hash>.rb/` with its own key. It is owned by [uid]
  /// (asserted like [openReplica]), never registered as the replica, and never
  /// reachable by [activeLocation] / [openReplica] until [swapStaging].
  Future<AppDatabase> openStaging(String uid) async {
    if (uid.isEmpty || uid.startsWith(_transitionPrefix)) {
      throw const ReplicaOwnershipException();
    }
    final hash = await uidHash(uid);
    final already = _staging[hash];
    if (already != null &&
        already.lifecycleState == DatabaseLifecycleState.open) {
      return already;
    }
    final loc = ReplicaLocation(
      directory: p.join(await _replicasRoot(), '$hash$stagingSuffix'),
      dbFileName: dbFileName,
      keyName: '$keyNamePrefix$hash$stagingSuffix',
    );
    final existed = await File(loc.dbPath).exists();
    final db = await _opener(location: loc, runMigrations: true);
    try {
      final owner = await _readMeta(db);
      if (owner == null && !existed) {
        await _writeMeta(db, uid);
      } else if (owner != uid) {
        throw const ReplicaOwnershipException();
      }
    } catch (_) {
      await db.close();
      rethrow;
    }
    return _staging[hash] = db;
  }

  /// Deletes the fresh replica (directory and key) of an abandoned rebootstrap.
  Future<void> discardStaging(String uid) async {
    final hash = await uidHash(uid);
    await _staging.remove(hash)?.close();
    final dir = Directory(p.join(await _replicasRoot(), '$hash$stagingSuffix'));
    if (await dir.exists()) await dir.delete(recursive: true);
    await _storage.delete(key: '$keyNamePrefix$hash$stagingSuffix');
  }

  /// Commits the swap: the live replica becomes `<hash>.old` (kept for
  /// [retiredReplicaRetention]) and the fresh one takes its place, then the
  /// marker is advanced to `swapped` and `retiredAt` stamped. Every step is
  /// decided from what is on disk, so a crash after any of [kSwapSteps] is
  /// finished by calling this again. Open handles are closed first; the caller
  /// reopens the replica through the account scope afterwards.
  Future<void> swapStaging(String uid) async {
    final hash = await uidHash(uid);
    await closeReplica(uid);
    await _staging.remove(hash)?.close();
    await _mutate(hash, (c) {
      final m = c?.rebootstrap;
      if (c == null || m == null) return c;
      return c.copyWith(
          rebootstrap: RebootstrapMarker(
              phase: m.phase,
              reason: m.reason,
              startedAt: m.startedAt,
              swapping: true));
    });
    final root = await _replicasRoot();
    final main = Directory(p.join(root, hash));
    final fresh = Directory(p.join(root, '$hash$stagingSuffix'));
    final old = Directory(p.join(root, '$hash$retiredSuffix'));
    final key = '$keyNamePrefix$hash';
    final freshKey = '$key$stagingSuffix';
    final oldKey = '$key$retiredSuffix';

    // A: not started (the live replica and the fresh one both exist). Any older
    // retained replica is superseded.
    if (await main.exists() && await fresh.exists()) {
      await _step('swap:beforeOldMoved');
      if (await old.exists()) await old.delete(recursive: true);
      await _storage.delete(key: oldKey);
      await main.rename(old.path);
      await _step('swap:afterOldMoved');
    }
    // B: the live replica is retired but its key is not yet kept under the old
    // name (the live key still is the old replica's: it is only replaced in E).
    if (!await main.exists() && await old.exists()) {
      final existing = await _storage.read(key: oldKey);
      if (existing == null || existing.isEmpty) {
        final k = await _storage.read(key: key);
        if (k != null && k.isNotEmpty) {
          await _storage.write(key: oldKey, value: k);
        }
      }
      await _step('swap:afterOldKey');
    }
    // C: the fresh replica takes the live name.
    if (!await main.exists() && await fresh.exists()) {
      await fresh.rename(main.path);
      await _step('swap:afterFreshMoved');
    }
    // D: the live key becomes the fresh replica's.
    final fk = await _storage.read(key: freshKey);
    if (fk != null && fk.isNotEmpty) {
      await _storage.write(key: key, value: fk);
      await _storage.delete(key: freshKey);
    }
    await _step('swap:afterFreshKey');
    if (!await main.exists()) {
      throw const FileSystemException('rebootstrap swap has no replica');
    }

    final hasOld = await old.exists();
    final now = _now();
    await _mutate(hash, (c) {
      if (c == null) return null;
      final m = c.rebootstrap;
      final already = m?.phase == RebootstrapPhase.swapped;
      return c.copyWith(
        state: ReplicaState.active,
        retiredAt: hasOld ? (already ? c.retiredAt ?? now : now) : null,
        rebootstrap: m == null
            ? null
            : RebootstrapMarker(
                phase: RebootstrapPhase.swapped,
                reason: m.reason,
                startedAt: m.startedAt),
      );
    });
  }

  /// Deletes retired replicas whose [retiredReplicaRetention] has passed (their
  /// directory and key). Safe to call on every launch.
  Future<void> purgeExpiredRetired() async {
    final now = _now();
    for (final e in await list()) {
      final at = e.retiredAt;
      if (at == null || now.difference(at) < retiredReplicaRetention) continue;
      final dir = Directory(
          p.join(await _replicasRoot(), '${e.uidHash}$retiredSuffix'));
      if (await dir.exists()) await dir.delete(recursive: true);
      await _storage.delete(key: '$keyNamePrefix${e.uidHash}$retiredSuffix');
      await _mutate(e.uidHash, (c) => c?.copyWith(clearRetiredAt: true));
    }
  }

  // ------------------------------------------------------------------ remove

  /// Deletes the replica of [uid]: its directory (database, WAL/SHM, every
  /// sidecar), its key and its registry entry. Only that uid's. Idempotent and
  /// crash-safe: the directory is first renamed (atomic) to a `_removing.<hash>`
  /// tombstone, then the key, the registry entry and the tombstone are removed;
  /// a crash after the rename is finished by [recoverPendingRemovals] (or by
  /// calling remove again). Open handles are closed first.
  Future<void> remove(String uid) async => _removeHash(await uidHash(uid));

  Future<void> _removeHash(String hash) async {
    await _open.remove(hash)?.close();
    await _staging.remove(hash)?.close();
    final root = await _replicasRoot();
    // The replica, plus the fresh one a rebootstrap was building (`.rb`) and the
    // one it retired (`.old`): Remove data deletes every copy of this uid's data.
    // The registry says which side copies exist, so the common case costs the
    // same file system calls as before WP-7.
    final entry = (await _readRegistry())[hash];
    final suffixes = [
      '',
      if (entry?.rebootstrap != null) stagingSuffix,
      if (entry?.retiredAt != null) retiredSuffix,
    ];
    final tombs = <Directory>[];
    for (final suffix in suffixes) {
      final dir = Directory(p.join(root, '$hash$suffix'));
      final tomb = Directory(p.join(root, '_removing.$hash$suffix'));
      if (await dir.exists()) {
        if (await tomb.exists()) await tomb.delete(recursive: true);
        await dir.rename(tomb.path);
      }
      tombs.add(tomb);
    }
    for (final suffix in suffixes) {
      await _storage.delete(key: '$keyNamePrefix$hash$suffix');
    }
    await _mutate(hash, (_) => null);
    for (final tomb in tombs) {
      if (await tomb.exists()) await tomb.delete(recursive: true);
    }
  }

  /// Finishes any removal that was interrupted after its directory rename.
  Future<void> recoverPendingRemovals() async {
    final root = Directory(await _replicasRoot());
    if (!await root.exists()) return;
    await for (final e in root.list()) {
      final name = p.basename(e.path);
      if (e is Directory && name.startsWith('_removing.')) {
        // `_removing.<hash>[.rb|.old]`; the hash is hex, so the first dot ends it.
        await _removeHash(name.substring('_removing.'.length).split('.').first);
        if (await e.exists()) await e.delete(recursive: true);
      }
    }
  }

  // ---------------------------------------------------------- legacy adoption

  /// True when a legacy database with no provable owner sits in
  /// `replicas/_quarantine/` (surface "This device has data from an unknown
  /// account"). Derived from the file system, so it survives registry loss.
  /// Quarantined files are never opened or inspected.
  Future<bool> hasQuarantinedLegacyData() async {
    final q = await _quarantineRoot();
    if (!await q.exists()) return false;
    await for (final e in q.list()) {
      if (e is Directory && p.basename(e.path).startsWith('legacy-')) {
        return true;
      }
    }
    return false;
  }

  /// One-time, crash-recoverable adoption of the legacy shared database (sync
  /// plan §05). Safe to call on every launch; also deletes `.adopted` files
  /// older than [adoptedGrace]. Never throws for ordinary failures: those return
  /// [AdoptionOutcome.failed] with the legacy file untouched and in use.
  Future<AdoptionOutcome> adoptLegacyIfPresent() async {
    final legacy = await _legacyLocation();
    final outcome = await _adoptOrQuarantine(legacy);
    await _purgeExpiredAdopted(legacy);
    return outcome;
  }

  Future<AdoptionOutcome> _adoptOrQuarantine(ReplicaLocation legacy) async {
    if (!await File(legacy.dbPath).exists()) {
      // A crash after the rename but before the registry bookkeeping.
      for (final e in await list()) {
        if (e.adoptPending && await File('${legacy.dbPath}.adopted').exists()) {
          await _mutate(
              e.uidHash,
              (c) => c?.copyWith(
                  adoptPending: false, legacyAdoptedAt: _now()));
        }
      }
      return AdoptionOutcome.none;
    }
    final marker = await _marker();
    if (marker == null || marker.isEmpty || marker.startsWith(_transitionPrefix)) {
      try {
        await _quarantine(legacy);
        return AdoptionOutcome.quarantined;
      } on Exception {
        return AdoptionOutcome.failed;
      }
    }
    final hash = await uidHash(marker);
    final entry = (await _readRegistry())[hash];
    if (entry != null && entry.state == ReplicaState.active && !entry.adoptPending) {
      return AdoptionOutcome.legacyLeftover;
    }
    final target = await _location(hash);
    try {
      if (entry != null &&
          entry.state == ReplicaState.active &&
          entry.adoptPending) {
        // Replica already verified and active; only the rename is outstanding.
        await _finishRename(legacy, hash);
        return AdoptionOutcome.adopted;
      }
      await _adopt(legacy, target, marker, hash);
      return AdoptionOutcome.adopted;
    } on Exception {
      return AdoptionOutcome.failed;
    }
  }

  Future<String?> _marker() => _readOwnerMarker != null
      ? _readOwnerMarker()
      : _storage.read(key: ownerMarkerKey);

  Future<void> _step(String name) async => _debugStep?.call(name);

  Future<void> _adopt(ReplicaLocation legacy, ReplicaLocation target,
      String uid, String hash) async {
    final now = _now();
    // Re-entrant start: `migrating` + adoptPending, whatever a previous attempt
    // left behind is discarded and redone from the (untouched) legacy file.
    await _mutate(
      hash,
      (c) => ReplicaEntry(
        uidHash: hash,
        createdAt: c?.createdAt ?? now,
        lastOpenedAt: now,
        schemaVersion: 0,
        epoch: 0,
        state: ReplicaState.migrating,
        adoptPending: true,
      ),
    );
    await _step('beforeCopy');
    final dir = Directory(target.directory);
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);

    // Fold any WAL into the main file so a plain file copy is complete.
    final src = await _opener(location: legacy, runMigrations: false);
    try {
      final row = await src
          .customSelect('PRAGMA wal_checkpoint(TRUNCATE);')
          .getSingle();
      if (row.read<int>('busy') != 0) {
        throw const FileSystemException('legacy checkpoint busy');
      }
    } finally {
      await src.close();
    }
    if (await File(legacy.walPath).exists() &&
        await File(legacy.walPath).length() > 0) {
      throw const FileSystemException('legacy WAL not folded');
    }
    await File(legacy.dbPath).copy(target.dbPath);
    await _step('afterCopy');

    final legacyKey = await _storage.read(key: legacy.keyName);
    if (legacyKey == null || legacyKey.isEmpty) {
      throw const LocalDatabaseKeyUnavailableException();
    }
    await _storage.write(key: target.keyName, value: legacyKey);
    await _step('afterKeyCopy');

    final copy = await _opener(location: target, runMigrations: true);
    try {
      final integrity =
          await copy.customSelect('PRAGMA integrity_check;').get();
      if (integrity.length != 1 ||
          integrity.single.read<String>('integrity_check') != 'ok') {
        throw const FileSystemException('adopted copy failed integrity check');
      }
      await copy.customSelect('SELECT count(*) FROM sqlite_master;').get();
      await _step('afterProbe');
      if (await _readMeta(copy) != null) {
        throw const FileSystemException('unexpected replica_meta in legacy');
      }
      await _writeMeta(copy, uid);
      await _step('afterReplicaMeta');
      final version = await _userVersion(copy);
      await _mutate(hash, (c) => c!.copyWith(schemaVersion: version));
    } finally {
      await copy.close();
    }
    await _mutate(hash, (c) => c!.copyWith(state: ReplicaState.active));
    await _step('afterRegistryActive');
    await _finishRename(legacy, hash);
  }

  /// Renames the legacy file (+ WAL/SHM, main file LAST so its existence stays
  /// the "adoption incomplete" signal) to `.adopted`, then stamps the grace
  /// start. Idempotent.
  Future<void> _finishRename(ReplicaLocation legacy, String hash) async {
    await _step('beforeRename');
    for (final path in [legacy.walPath, legacy.shmPath, legacy.dbPath]) {
      final f = File(path);
      if (await f.exists()) await f.rename('$path.adopted');
    }
    await _step('afterRename');
    await _mutate(hash,
        (c) => c?.copyWith(adoptPending: false, legacyAdoptedAt: _now()));
  }

  /// Moves the legacy file with no provable owner into `_quarantine/` without
  /// opening it. Staged through `incoming/` so a crash mid-move resumes into the
  /// same directory (main file moved last).
  Future<void> _quarantine(ReplicaLocation legacy) async {
    final root = await _quarantineRoot();
    final staging = Directory(p.join(root.path, 'incoming'));
    await staging.create(recursive: true);
    for (final path in [legacy.walPath, legacy.shmPath, legacy.dbPath]) {
      final f = File(path);
      if (await f.exists()) await f.rename(p.join(staging.path, p.basename(path)));
    }
    await staging.rename(
        p.join(root.path, 'legacy-${_now().microsecondsSinceEpoch}'));
  }

  /// Deletes `.adopted` legacy files whose 7-day grace has passed (P2 rollback
  /// window over). Also drops the legacy key, but only when no legacy database
  /// file exists that would still need it.
  Future<void> _purgeExpiredAdopted(ReplicaLocation legacy) async {
    final now = _now();
    for (final e in await list()) {
      final at = e.legacyAdoptedAt;
      if (at == null || now.difference(at) < adoptedGrace) continue;
      for (final path in [legacy.walPath, legacy.shmPath, legacy.dbPath]) {
        final f = File('$path.adopted');
        if (await f.exists()) await f.delete();
      }
      if (!await File(legacy.dbPath).exists()) {
        await _storage.delete(key: legacy.keyName);
      }
      await _mutate(e.uidHash, (c) => c?.copyWith(clearLegacyAdoptedAt: true));
    }
  }
}
