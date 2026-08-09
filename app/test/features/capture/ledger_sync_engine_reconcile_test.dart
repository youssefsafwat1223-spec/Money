import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/financial_cache_health.dart';
import 'package:money_companion/data/db/legacy_financial_cache_reconciler.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/features/capture/services/ledger_push_service.dart';
import 'package:money_companion/features/capture/services/ledger_sync_engine.dart';
import 'package:money_companion/features/capture/services/ledger_sync_service.dart';

// MALI-034: LedgerSyncEngine in-slot call order + cancellation. Proves push
// ALWAYS precedes the pull slot, the pull slot is a normal pull (clean) or an
// epoch pull (dirty), cancellation returns immediately after push, and the
// exact-generation guard reaches even the normal pull (requirement 2).

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

Future<AppDatabase> _openDb() =>
    AppDatabase.open(executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());

Future<void> _seedDirty(AppDatabase db) => db.customStatement(
      "INSERT INTO financial_cache_health(entity_type, dirty, marked_at) "
      "VALUES ('transactions', 1, '2020-01-01T00:00:00.000Z');",
    );

class _RecordingPush implements LedgerPushAdapter {
  _RecordingPush(this.log);
  final List<String> log;
  @override
  Future<LedgerPushResult> push() async {
    log.add('push');
    return const LedgerPushResult();
  }
}

class _RecordingPull implements LedgerPullAdapter {
  _RecordingPull(this.log, {this.result = const LedgerSyncResult()});
  final List<String> log;
  final LedgerSyncResult result;
  SyncCursor? seenFrom;
  bool sawIsAdmitted = false;
  int calls = 0;
  @override
  Future<LedgerSyncResult> pull({SyncCursor? from, bool Function()? isAdmitted}) async {
    calls++;
    seenFrom = from;
    sawIsAdmitted = isAdmitted != null;
    log.add(from == null ? 'pull' : 'pull(epoch)');
    return result;
  }
}

LegacyFinancialCacheReconciler _reconciler(AppDatabase db, {required bool admitted}) =>
    LegacyFinancialCacheReconciler(
        db: db, generation: 1, isAdmitted: (_) => admitted);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('clean domain: push THEN normal pull (no epoch); guard reaches normal pull',
      () async {
    final db = await _openDb();
    addTearDown(db.close);
    final log = <String>[];
    final pull = _RecordingPull(log);
    final engine =
        LedgerSyncEngine(pushService: _RecordingPush(log), pullService: pull);

    final r = await engine.sync(reconciler: _reconciler(db, admitted: true));

    expect(log, ['push', 'pull']);
    expect(pull.seenFrom, isNull, reason: 'clean -> normal incremental pull');
    expect(pull.sawIsAdmitted, isTrue,
        reason: 'req 2: normal pull also gets the exact-generation guard');
    expect(r, ReconcileDomainResult.noDirtyState);
  });

  test('dirty domain + admitted: push THEN epoch pull; marker cleared; no dup pull',
      () async {
    final db = await _openDb();
    addTearDown(db.close);
    await _seedDirty(db);
    final log = <String>[];
    final pull = _RecordingPull(log,
        result: const LedgerSyncResult(status: SyncPullStatus.completed));
    final engine =
        LedgerSyncEngine(pushService: _RecordingPush(log), pullService: pull);

    final r = await engine.sync(reconciler: _reconciler(db, admitted: true));

    expect(log, ['push', 'pull(epoch)']);
    expect(pull.seenFrom?.updatedAt, syncCursorEpoch);
    expect(pull.calls, 1, reason: 'epoch pull REPLACES the normal pull');
    expect(r, ReconcileDomainResult.completed);
    expect(await isFinancialCacheDirty(db, 'transactions'), isFalse);
  });

  test('dirty domain + generation invalid: push only, pull NOT run, cancelled',
      () async {
    final db = await _openDb();
    addTearDown(db.close);
    await _seedDirty(db);
    final log = <String>[];
    final pull = _RecordingPull(log);
    final engine =
        LedgerSyncEngine(pushService: _RecordingPush(log), pullService: pull);

    final r = await engine.sync(reconciler: _reconciler(db, admitted: false));

    expect(log, ['push'], reason: 'cancelled before the pull slot runs');
    expect(pull.calls, 0);
    expect(r, ReconcileDomainResult.cancelled);
    expect(await isFinancialCacheDirty(db, 'transactions'), isTrue);
  });

  test('dirty domain + pull failed: epoch pull ONCE, marker stays, failed',
      () async {
    final db = await _openDb();
    addTearDown(db.close);
    await _seedDirty(db);
    final log = <String>[];
    final pull = _RecordingPull(log,
        result: const LedgerSyncResult(status: SyncPullStatus.failed));
    final engine =
        LedgerSyncEngine(pushService: _RecordingPush(log), pullService: pull);

    final r = await engine.sync(reconciler: _reconciler(db, admitted: true));

    expect(pull.calls, 1, reason: 'no second same-invocation pull for a failed attempt');
    expect(r, ReconcileDomainResult.failed);
    expect(await isFinancialCacheDirty(db, 'transactions'), isTrue);
  });
}
