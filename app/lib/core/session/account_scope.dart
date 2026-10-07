import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';

import '../../data/db/app_database.dart';
import '../../data/db/planning_cutover.dart';
import '../../data/db/replica_location.dart';
import '../../data/db/replica_store.dart';

/// WP-3b — the ACCOUNT SCOPE: the one database the UI and every service work
/// against, and the uid it belongs to.
///
/// A scope is immutable. A switch (sign-in of another uid, sign-out, removal)
/// never mutates one: the old scope is withdrawn first ([AccountScopeHost.current]
/// becomes null so the root widget disposes every provider built on it), the old
/// database is closed, and only then is the next one opened and published under a
/// new [generation]. So no handle to one uid's database can be reached from
/// another uid's scope: the previous one is closed before the next exists.
@immutable
class AccountScope {
  const AccountScope({
    required this.generation,
    required this.uid,
    required this.database,
    required this.location,
    this.hasLocalData = true,
    this.planningCutoverState = PlanningCutoverState.canonical,
  });

  /// Strictly increasing across the process; the root `ProviderScope` is keyed
  /// by it.
  final int generation;

  /// Null for the SIGNED-OUT scope: an in-memory, never-persisted database that
  /// only lets the pre-login screens render. It holds no account data.
  final String? uid;
  final AppDatabase database;

  /// Null for the signed-out scope; the legacy location while a failed adoption
  /// keeps the legacy file in use.
  final ReplicaLocation? location;
  final bool hasLocalData;
  final PlanningCutoverState planningCutoverState;
}

/// What the per-account startup steps resolved for a freshly opened database.
class AccountScopeInit {
  const AccountScopeInit({
    this.hasLocalData = true,
    this.planningCutoverState = PlanningCutoverState.canonical,
  });
  final bool hasLocalData;
  final PlanningCutoverState planningCutoverState;
}

/// What AppSession needs from the account-scope layer (kept narrow so the session
/// layer stays decoupled from the database layer, like its other hooks).
abstract class AccountScopeControl {
  /// An authenticated uid is admitted: unlock its replica (registry `active`),
  /// open it and publish it, locking and closing any other uid's replica first.
  Future<void> activate(String uid);

  /// Explicit sign-out: lock the active replica (registry `locked`), close it and
  /// publish the signed-out scope. Nothing is deleted.
  Future<void> lock();

  /// Remove-data step 2: close the active scope WITHOUT locking, because the
  /// replica is about to be deleted. Publishes the signed-out scope.
  Future<void> detach();
}

class AccountScopeHost extends ChangeNotifier implements AccountScopeControl {
  AccountScopeHost({
    required this.store,
    required this.initialize,
    Future<AppDatabase> Function()? openSignedOut,
    Future<void> Function(ReplicaLocation location)? prepareLocation,
    Future<void> Function()? afterWithdraw,
  })  : _openSignedOut = openSignedOut ?? _defaultSignedOut,
        _prepareLocation = prepareLocation,
        _afterWithdraw = afterWithdraw ?? (() => Future<void>.delayed(Duration.zero));

  final ReplicaStore store;

  /// Per-account startup steps (seed, flags, hooks, repairs). Run on every
  /// database before it is published; a throw closes it and fails the switch.
  final Future<AccountScopeInit> Function(AppDatabase db, String? uid) initialize;
  final Future<AppDatabase> Function() _openSignedOut;
  final Future<void> Function(ReplicaLocation location)? _prepareLocation;

  /// Completes once the withdrawn scope has been torn down by the UI.
  final Future<void> Function() _afterWithdraw;

  static Future<AppDatabase> _defaultSignedOut() =>
      AppDatabase.open(executor: NativeDatabase.memory());

  AccountScope? _current;
  int _generation = 0;
  Future<void> _tail = Future<void>.value();

  /// The published scope; null only while a switch is in flight.
  AccountScope? get current => _current;
  String? get activeUid => _current?.uid;
  int get generation => _generation;

  Future<T> _serial<T>(Future<T> Function() f) {
    final run = _tail.then((_) => f());
    _tail = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  /// Launch: open [uid]'s replica WITHOUT unlocking it (a locked replica must stay
  /// closed until its uid authenticates, SYNC-Q3). A locked / quarantined replica
  /// or a null [uid] opens the signed-out scope.
  Future<AccountScope> openAtLaunch(String? uid) => _serial(() async {
        await _withdraw();
        if (uid != null) {
          try {
            return await _publishOpened(uid, await _openAccount(uid));
          } on ReplicaUnavailableException {
            // Locked (signed out, SYNC-Q3) or quarantined: stays closed.
          }
        }
        return _publishSignedOut();
      });

  @override
  Future<void> activate(String uid) => _serial(() async {
        if (_current?.uid == uid &&
            _current!.database.lifecycleState == DatabaseLifecycleState.open) {
          await store.setState(uid, ReplicaState.active);
          return;
        }
        await _withdraw(lockPrevious: true);
        await store.setState(uid, ReplicaState.active);
        try {
          await _publishOpened(uid, await _openAccount(uid));
        } catch (_) {
          await _publishSignedOut();
          rethrow;
        }
      });

  @override
  Future<void> lock() => _serial(() async {
        await _withdraw(lockPrevious: true);
        await _publishSignedOut();
      });

  @override
  Future<void> detach() => _serial(() async {
        if (_current == null) return; // launch-time resume: nothing is open yet
        await _withdraw();
        await _publishSignedOut();
      });

  /// Launch, FIRST (before anything reads or writes the owner marker): finishes a
  /// removal that was interrupted after its directory rename, then adopts the
  /// legacy shared database into its owner's replica (or quarantines it when no
  /// owner is provable, B4). Must run before the session reconcile claims the
  /// marker, or an unowned legacy file would be adopted by whoever is restored.
  Future<AdoptionOutcome> recoverAtLaunch() async {
    await store.recoverPendingRemovals();
    final outcome = await store.adoptLegacyIfPresent();
    // WP-7: a replica a swapped rebootstrap retired is deleted after 14 days.
    await store.purgeExpiredRetired();
    return outcome;
  }

  /// Opens the uid's replica; a `migrating` one (interrupted adoption) is retried
  /// once, and while it still cannot finish the legacy file stays in use.
  Future<(AppDatabase, ReplicaLocation?)> _openAccount(String uid) async {
    try {
      return await _openReplica(uid);
    } on ReplicaUnavailableException catch (e) {
      if (e.state != ReplicaState.migrating) rethrow;
    }
    final outcome = await store.adoptLegacyIfPresent();
    if (outcome == AdoptionOutcome.adopted) return _openReplica(uid);
    final legacy = await store.legacyLocation();
    await _prepareLocation?.call(legacy);
    return (await AppDatabase.open(location: legacy), legacy);
  }

  Future<(AppDatabase, ReplicaLocation?)> _openReplica(String uid) async {
    final db = await store.openReplica(uid);
    return (db, await store.locationFor(uid));
  }

  Future<AccountScope> _publishOpened(
      String uid, (AppDatabase, ReplicaLocation?) opened) async {
    final (db, location) = opened;
    return _publish(db, uid, location, closeOnFailure: () => _close(db, uid));
  }

  Future<AccountScope> _publishSignedOut() async {
    final db = await _openSignedOut();
    return _publish(db, null, null, closeOnFailure: () => _close(db, null));
  }

  Future<AccountScope> _publish(
    AppDatabase db,
    String? uid,
    ReplicaLocation? location, {
    required Future<void> Function() closeOnFailure,
  }) async {
    final AccountScopeInit init;
    try {
      init = await initialize(db, uid);
    } catch (_) {
      await closeOnFailure();
      rethrow;
    }
    final scope = AccountScope(
      generation: ++_generation,
      uid: uid,
      database: db,
      location: location,
      hasLocalData: init.hasLocalData,
      planningCutoverState: init.planningCutoverState,
    );
    _current = scope;
    notifyListeners();
    return scope;
  }

  Future<void> _close(AppDatabase db, String? uid) async {
    if (uid != null) await store.closeReplica(uid);
    await db.close(); // idempotent; covers the legacy-in-use handle too
  }

  /// Withdraws the published scope (the UI disposes every provider built on it),
  /// then closes its database. Optionally locks the previous uid's replica FIRST,
  /// so a crash mid-switch leaves it locked, never open to the next sign-in.
  Future<void> _withdraw({bool lockPrevious = false}) async {
    final prev = _current;
    if (prev == null) return;
    if (lockPrevious && prev.uid != null) {
      await store.setState(prev.uid!, ReplicaState.locked);
    }
    _current = null;
    notifyListeners();
    await _afterWithdraw();
    await _close(prev.database, prev.uid);
  }
}
