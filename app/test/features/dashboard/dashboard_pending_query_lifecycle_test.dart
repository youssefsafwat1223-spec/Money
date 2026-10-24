import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/session/account_scope.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/replica_store.dart';
import 'package:money_companion/features/dashboard/dashboard_providers.dart';

// O-R9 (Astra R8 Q5) — every future the dashboard provider starts has an error
// consumer, whichever await fails first and whether or not the provider is still
// alive. The queries are held DETERMINISTICALLY (a gated query interceptor), never
// by a delay; "nothing escaped" is asserted after owned producers complete.

class _Key implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

/// Holds every SELECT that [matches] until [release] completes; optionally
/// fails each held one then.
class _Gate extends QueryInterceptor {
  _Gate(this.matches, {this.failOnRelease = false});
  final bool Function(String sql) matches;
  final bool failOnRelease;
  final Completer<void> release = Completer<void>();
  final Completer<void> reached = Completer<void>();
  bool armed = false;
  final List<String> held = [];
  int active = 0;
  int finished = 0;
  Completer<void>? _idle;

  Future<void> get drained => active == 0
      ? Future<void>.value()
      : (_idle ??= Completer<void>()).future;

  @override
  Future<List<Map<String, Object?>>> runSelect(
      QueryExecutor executor, String statement, List<Object?> args) async {
    active++;
    try {
      if (armed && matches(statement)) {
        held.add(statement);
        if (!reached.isCompleted) reached.complete();
        await release.future;
        if (failOnRelease) throw StateError('held query failed');
      }
      return await executor.runSelect(statement, args);
    } finally {
      finished++;
      if (--active == 0) {
        _idle?.complete();
        _idle = null;
      }
    }
  }
}

Future<AppDatabase> _open(_Gate gate) async {
  final db = await AppDatabase.open(
      executor: NativeDatabase.memory().interceptWith(gate), keyStore: _Key());
  // Schema initialization has transaction SELECTs of its own. Only hold the
  // dashboard reads that the test starts after opening completes.
  gate.armed = true;
  return db;
}

/// Runs [body] in a zone that records every uncaught asynchronous error.
Future<List<Object>> _recordingUncaught(
    Future<void> Function() body, {void Function(Zone)? onZone}) async {
  final uncaught = <Object>[];
  final owner = Zone.current;
  var closed = false;
  final done = Completer<void>();
  runZonedGuarded(() async {
    onZone?.call(Zone.current);
    try {
      await body();
      done.complete();
    } catch (e, st) {
      done.completeError(e, st);
    }
  }, (e, st) {
    if (closed) {
      owner.handleUncaughtError(e, st);
    } else {
      uncaught.add(e);
    }
  });
  try {
    await done.future;
  } finally {
    closed = true;
  }
  return uncaught;
}

Future<void> _waitUntilHeld(_Gate gate) async {
  await gate.reached.future.timeout(const Duration(seconds: 10));
}

void _release(_Gate gate) {
  if (!gate.release.isCompleted) gate.release.complete();
}

void main() {
  for (final teardown in [false, true]) {
    test('O9-3 closed dashboard sink forwards errors '
        '${teardown ? 'during teardown' : 'after returning'}', () async {
      final forwarded = <Object>[];
      final done = Completer<List<Object>>();
      late Zone producer;
      runZonedGuarded(() async {
        done.complete(await _recordingUncaught(() async {},
            onZone: (zone) => producer = zone));
      }, (error, stack) => forwarded.add(error));
      final seen = await done.future;
      void injectAndVerify() {
        final error = StateError('closed-dashboard-sink');
        producer.handleUncaughtError(error, StackTrace.current);
        expect(forwarded, [same(error)]);
        expect(seen, isEmpty,
            reason: 'closed collection cannot consume late failures');
      }

      if (teardown) {
        addTearDown(injectAndVerify);
      } else {
        injectAndVerify();
      }
    });
  }

  test(
      'a failure of the first aggregate group leaves no unconsumed error from '
      'the reads started beside it', () async {
    final gate = _Gate((sql) => sql.contains('transactions'),
        failOnRelease: true);
    final db = await _open(gate);
    addTearDown(db.close);
    addTearDown(() => _release(gate));
    final uncaught = await _recordingUncaught(() async {
      final container = ProviderContainer(
          overrides: [appDatabaseProvider.overrideWithValue(db)]);
      addTearDown(container.dispose);
      final read = container.read(dashboardDataProvider.future);
      final outcome = read.then<Object?>((_) => null, onError: (Object e) => e);
      await _waitUntilHeld(gate);
      gate.release.complete();
      expect(await outcome, isNotNull, reason: 'the provider reports failure');
      await gate.drained;
      expect(gate.active, 0);
    });
    expect(uncaught, isEmpty,
        reason: 'every started read has an error consumer');
  });

  test(
      'a failure of the second read group leaves no unconsumed error from the '
      'previous-window breakdown', () async {
    final gate =
        _Gate((sql) => sql.toUpperCase().contains('GROUP BY'), failOnRelease: true);
    final db = await _open(gate);
    addTearDown(db.close);
    addTearDown(() => _release(gate));
    final uncaught = await _recordingUncaught(() async {
      final container = ProviderContainer(
          overrides: [appDatabaseProvider.overrideWithValue(db)]);
      addTearDown(container.dispose);
      final read = container.read(dashboardDataProvider.future);
      final outcome = read.then<Object?>((_) => null, onError: (Object e) => e);
      await _waitUntilHeld(gate);
      gate.release.complete();
      expect(await outcome, isNotNull);
      await gate.drained;
      expect(gate.active, 0);
    });
    expect(uncaught, isEmpty);
  });

  test('a provider disposed while its reads are pending leaves nothing '
      'unconsumed when they fail', () async {
    final gate = _Gate((sql) => sql.contains('transactions'),
        failOnRelease: true);
    final db = await _open(gate);
    addTearDown(db.close);
    addTearDown(() => _release(gate));
    final uncaught = await _recordingUncaught(() async {
      final container = ProviderContainer(
          overrides: [appDatabaseProvider.overrideWithValue(db)]);
      final read = container.read(dashboardDataProvider.future);
      final outcome = read.then<Object?>((_) => null, onError: (Object e) => e);
      await _waitUntilHeld(gate);
      container.dispose();
      gate.release.complete();
      expect(await outcome, isNotNull);
      await gate.drained;
      expect(gate.active, 0);
      expect(gate.finished, greaterThanOrEqualTo(gate.held.length));
    });
    expect(uncaught, isEmpty);
  });

  test(
      'a real scope transition while the dashboard query is pending: the '
      'withdrawn scope\'s reads end without any unconsumed error', () async {
    final support = Directory.systemTemp.createTempSync('dash_pending_');
    addTearDown(() => support.deleteSync(recursive: true));
    final gate = _Gate((sql) => sql.contains('transactions'));
    var opens = 0;
    final host = AccountScopeHost.uncoordinatedForTesting(
      store: ReplicaStore(appSupportDirectory: support.path),
      initialize: (db, uid) async => const AccountScopeInit(),
      openSignedOut: () => opens++ == 0
          ? _open(gate)
          : AppDatabase.open(
              executor: NativeDatabase.memory(), keyStore: _Key()),
    );
    addTearDown(host.dispose);
    addTearDown(() => _release(gate));
    await host.openAtLaunch(null);
    final first = host.current!;
    final uncaught = await _recordingUncaught(() async {
      final container = ProviderContainer(overrides: [
        appDatabaseProvider.overrideWithValue(first.database),
      ]);
      addTearDown(container.dispose);
      final read = container.read(dashboardDataProvider.future);
      final outcome = read.then<Object?>((_) => null, onError: (Object e) => e);
      await _waitUntilHeld(gate);
      // The REAL transition: the scope is withdrawn and its database closed
      // while the dashboard query is still pending; the successor is published.
      final withdrawn = Completer<void>();
      void onChanged() {
        if (host.current == null && !withdrawn.isCompleted) {
          withdrawn.complete();
        }
      }
      host.addListener(onChanged);
      final transition = host.lock();
      await withdrawn.future;
      host.removeListener(onChanged);
      expect(host.current, isNull,
          reason: 'the original scope is withdrawn while its query is held');
      expect(gate.release.isCompleted, isFalse);
      expect(gate.active, greaterThan(0));
      gate.release.complete();
      await transition;
      await outcome;
      await gate.drained;
      expect(gate.active, 0);
      container.dispose();
    });
    expect(identical(host.current, first), isFalse,
        reason: 'the scope really changed');
    expect(uncaught, isEmpty,
        reason: 'the transition leaves no unconsumed asynchronous error');
  });
}
