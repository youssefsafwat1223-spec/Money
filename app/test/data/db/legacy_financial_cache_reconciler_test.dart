import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/financial_cache_health.dart';
import 'package:money_companion/data/db/financial_cache_reconcile_map.dart';
import 'package:money_companion/data/db/legacy_financial_cache_reconciler.dart';

// MALI-034: reconcileDomain is the SINGLE primitive used by both production
// (in-slot wiring) and these tests — it clears a legacy dirty marker only on
// true-EOF completion under a still-valid admission generation, and
// distinguishes lifecycle cancellation from transport failure. Fake domains
// exercise the decision logic in isolation; the real pull services' status/
// cursor semantics are proven in the per-puller contract tests.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

Future<AppDatabase> _openDb() =>
    AppDatabase.open(executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());

Future<void> _seedDirty(AppDatabase db, String entity) => db.customStatement(
      "INSERT INTO financial_cache_health(entity_type, dirty, marked_at) "
      "VALUES (?, 1, '2020-01-01T00:00:00.000Z');",
      [entity],
    );

ReconcileDomain _domain({
  required String name,
  required Set<String> entities,
  bool enabled = true,
  required Future<Set<String>> Function(
          Set<String> dirty, bool Function() admitted)
      run,
}) =>
    ReconcileDomain(
      name: name,
      entities: entities,
      isEnabled: () => enabled,
      runFromEpoch: ({required dirtyEntities, required isAdmitted}) =>
          run(dirtyEntities, isAdmitted),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Mutable generation modelling SyncGate.admits: admitted iff captured gen ==
  // current. Bumping models sign-out.
  late int currentGen;
  bool admits(int g) => g == currentGen;
  setUp(() => currentGen = 1);

  LegacyFinancialCacheReconciler reconciler(AppDatabase db, {int gen = 1}) =>
      LegacyFinancialCacheReconciler(db: db, generation: gen, isAdmitted: admits);

  test('noDirtyState: no marker -> no-op, pull never invoked', () async {
    final db = await _openDb();
    addTearDown(db.close);
    var invoked = false;
    final r = await reconciler(db).reconcileDomain(_domain(
      name: 'accounts',
      entities: {'accounts'},
      run: (_, __) async {
        invoked = true;
        return {'accounts'};
      },
    ));
    expect(r, ReconcileDomainResult.noDirtyState);
    expect(invoked, isFalse);
  });

  test('completed: EOF + admitted -> marker cleared', () async {
    final db = await _openDb();
    addTearDown(db.close);
    await _seedDirty(db, 'accounts');
    final r = await reconciler(db).reconcileDomain(_domain(
      name: 'accounts',
      entities: {'accounts'},
      run: (dirty, _) async => dirty,
    ));
    expect(r, ReconcileDomainResult.completed);
    expect(await isFinancialCacheDirty(db, 'accounts'), isFalse);
  });

  test('deferred: disabled -> not attempted, marker remains', () async {
    final db = await _openDb();
    addTearDown(db.close);
    await _seedDirty(db, 'accounts');
    var invoked = false;
    final r = await reconciler(db).reconcileDomain(_domain(
      name: 'accounts',
      entities: {'accounts'},
      enabled: false,
      run: (_, __) async {
        invoked = true;
        return {'accounts'};
      },
    ));
    expect(r, ReconcileDomainResult.deferred);
    expect(invoked, isFalse);
    expect(await isFinancialCacheDirty(db, 'accounts'), isTrue);
  });

  test('failed: no EOF -> marker remains, not completed', () async {
    final db = await _openDb();
    addTearDown(db.close);
    await _seedDirty(db, 'accounts');
    final r = await reconciler(db).reconcileDomain(_domain(
      name: 'accounts',
      entities: {'accounts'},
      run: (_, __) async => <String>{},
    ));
    expect(r, ReconcileDomainResult.failed);
    expect(await isFinancialCacheDirty(db, 'accounts'), isTrue);
  });

  test('cancelled before work: admission invalid at start -> pull never invoked',
      () async {
    final db = await _openDb();
    addTearDown(db.close);
    await _seedDirty(db, 'accounts');
    currentGen = 2;
    var invoked = false;
    final r = await reconciler(db).reconcileDomain(_domain(
      name: 'accounts',
      entities: {'accounts'},
      run: (_, __) async {
        invoked = true;
        return {'accounts'};
      },
    ));
    expect(r, ReconcileDomainResult.cancelled);
    expect(invoked, isFalse);
    expect(await isFinancialCacheDirty(db, 'accounts'), isTrue);
  });

  test('cancelled during pull: admission lost mid-pull -> marker NOT cleared',
      () async {
    final db = await _openDb();
    addTearDown(db.close);
    await _seedDirty(db, 'accounts');
    final r = await reconciler(db).reconcileDomain(_domain(
      name: 'accounts',
      entities: {'accounts'},
      run: (dirty, _) async {
        currentGen = 2;
        return dirty;
      },
    ));
    expect(r, ReconcileDomainResult.cancelled);
    expect(await isFinancialCacheDirty(db, 'accounts'), isTrue);
  });

  test(
      'post-EOF / pre-clear invalidation: EOF then generation changes before '
      'clear -> marker MUST remain; next valid gen clears it', () async {
    final db = await _openDb();
    addTearDown(db.close);
    await _seedDirty(db, 'accounts');
    final r = await reconciler(db).reconcileDomain(_domain(
      name: 'accounts',
      entities: {'accounts'},
      run: (dirty, admitted) async {
        expect(admitted(), isTrue);
        currentGen = 2; // sign-out AFTER EOF, before clear
        return dirty;
      },
    ));
    expect(r, ReconcileDomainResult.cancelled);
    expect(await isFinancialCacheDirty(db, 'accounts'), isTrue,
        reason: 'a stale generation must never clear the marker');

    currentGen = 2;
    final r2 = await reconciler(db, gen: 2).reconcileDomain(_domain(
      name: 'accounts',
      entities: {'accounts'},
      run: (dirty, _) async => dirty,
    ));
    expect(r2, ReconcileDomainResult.completed);
    expect(await isFinancialCacheDirty(db, 'accounts'), isFalse);
  });

  test('planning partial: budget EOF, goal not -> clears only budget, failed',
      () async {
    final db = await _openDb();
    addTearDown(db.close);
    await _seedDirty(db, 'budgets');
    await _seedDirty(db, 'goals');
    final r = await reconciler(db).reconcileDomain(_domain(
      name: 'planning',
      entities: {'budgets', 'goals', 'subscriptions', 'plans'},
      run: (dirty, _) async => {'budgets'},
    ));
    expect(r, ReconcileDomainResult.failed);
    expect(await isFinancialCacheDirty(db, 'budgets'), isFalse);
    expect(await isFinancialCacheDirty(db, 'goals'), isTrue);
  });

  test('planning all EOF -> all cleared, completed', () async {
    final db = await _openDb();
    addTearDown(db.close);
    await _seedDirty(db, 'budgets');
    await _seedDirty(db, 'goals');
    final r = await reconciler(db).reconcileDomain(_domain(
      name: 'planning',
      entities: {'budgets', 'goals', 'subscriptions', 'plans'},
      run: (dirty, _) async => dirty,
    ));
    expect(r, ReconcileDomainResult.completed);
    expect(await isFinancialCacheDirty(db, 'budgets'), isFalse);
    expect(await isFinancialCacheDirty(db, 'goals'), isFalse);
  });

  test('aggregate precedence: cancelled > failed > deferred > completed > none',
      () {
    expect(
      aggregateReconcileResult(
          [ReconcileDomainResult.completed, ReconcileDomainResult.deferred]),
      ReconcileDomainResult.deferred,
      reason: 'completed + deferred must NOT report as completed',
    );
    expect(
      aggregateReconcileResult([
        ReconcileDomainResult.completed,
        ReconcileDomainResult.failed,
        ReconcileDomainResult.noDirtyState,
      ]),
      ReconcileDomainResult.failed,
    );
    expect(
      aggregateReconcileResult(
          [ReconcileDomainResult.failed, ReconcileDomainResult.cancelled]),
      ReconcileDomainResult.cancelled,
    );
    expect(
      aggregateReconcileResult(
          [ReconcileDomainResult.noDirtyState, ReconcileDomainResult.completed]),
      ReconcileDomainResult.completed,
    );
    expect(aggregateReconcileResult(const []),
        ReconcileDomainResult.noDirtyState);
  });

  test('multi-domain via reconcileDomain + aggregate', () async {
    final db = await _openDb();
    addTearDown(db.close);
    await _seedDirty(db, 'transactions');
    await _seedDirty(db, 'smart_inbox');
    final rec = reconciler(db);
    final results = <ReconcileDomainResult>[
      await rec.reconcileDomain(_domain(
          name: 'accounts', entities: {'accounts'}, run: (d, _) async => d)),
      await rec.reconcileDomain(_domain(
          name: 'ledger', entities: {'transactions'}, run: (d, _) async => d)),
      await rec.reconcileDomain(_domain(
          name: 'smart_inbox',
          entities: {'smart_inbox'},
          enabled: false,
          run: (d, _) async => d)),
    ];
    expect(results[0], ReconcileDomainResult.noDirtyState);
    expect(results[1], ReconcileDomainResult.completed);
    expect(results[2], ReconcileDomainResult.deferred);
    expect(aggregateReconcileResult(results), ReconcileDomainResult.deferred);
    expect(await isFinancialCacheDirty(db, 'transactions'), isFalse);
    expect(await isFinancialCacheDirty(db, 'smart_inbox'), isTrue);
  });

  test(
      'atomic clear boundary: generation invalid at the mutation boundary -> '
      'marker stays (no separate check/mutate window)', () async {
    final db = await _openDb();
    addTearDown(db.close);
    await _seedDirty(db, 'accounts');
    // Not admitted at the mutation boundary -> no clear.
    final cleared =
        await clearFinancialCacheDirtyIfAdmitted(db, 'accounts', () => false);
    expect(cleared, isFalse);
    expect(await isFinancialCacheDirty(db, 'accounts'), isTrue);
    // Admitted -> clears.
    final cleared2 =
        await clearFinancialCacheDirtyIfAdmitted(db, 'accounts', () => true);
    expect(cleared2, isTrue);
    expect(await isFinancialCacheDirty(db, 'accounts'), isFalse);
  });

  // ── reconcileOrPull slot decision (the in-slot primitive) ──────────────────

  test('reconcileOrPull: null reconciler -> normal pull runs (admitted)', () async {
    final db = await _openDb();
    addTearDown(db.close);
    var pulled = false;
    final r = await reconcileOrPull(
      reconciler: null,
      domain: _domain(
          name: 'accounts', entities: {'accounts'}, run: (_, __) async => {'accounts'}),
      normalPull: (admitted) async {
        pulled = true;
        expect(admitted(), isTrue);
      },
    );
    expect(r, ReconcileDomainResult.noDirtyState);
    expect(pulled, isTrue);
  });

  test('reconcileOrPull: clean domain -> normal pull, epoch NOT used', () async {
    final db = await _openDb();
    addTearDown(db.close);
    var pulled = false;
    var epochRan = false;
    final r = await reconcileOrPull(
      reconciler: reconciler(db),
      domain: _domain(
          name: 'accounts',
          entities: {'accounts'},
          run: (_, __) async {
            epochRan = true;
            return {'accounts'};
          }),
      normalPull: (admitted) async => pulled = true,
    );
    expect(r, ReconcileDomainResult.noDirtyState);
    expect(pulled, isTrue);
    expect(epochRan, isFalse);
  });

  test('reconcileOrPull: dirty domain -> epoch REPLACES normal pull', () async {
    final db = await _openDb();
    addTearDown(db.close);
    await _seedDirty(db, 'accounts');
    var pulled = false;
    final r = await reconcileOrPull(
      reconciler: reconciler(db),
      domain: _domain(
          name: 'accounts',
          entities: {'accounts'},
          run: (d, _) async => d),
      normalPull: (admitted) async => pulled = true,
    );
    expect(r, ReconcileDomainResult.completed);
    expect(pulled, isFalse, reason: 'epoch pull replaces the normal pull');
  });

  test('reconcileOrPull: cancelled propagates, normal pull not run', () async {
    final db = await _openDb();
    addTearDown(db.close);
    await _seedDirty(db, 'accounts');
    currentGen = 2; // captured gen 1 no longer admitted
    var pulled = false;
    final r = await reconcileOrPull(
      reconciler: reconciler(db),
      domain: _domain(
          name: 'accounts', entities: {'accounts'}, run: (d, _) async => d),
      normalPull: (admitted) async => pulled = true,
    );
    expect(r, ReconcileDomainResult.cancelled);
    expect(pulled, isFalse);
  });

  test('unsupportedDirtyMarkers: unknown marker surfaced, known excluded',
      () async {
    final db = await _openDb();
    addTearDown(db.close);
    await _seedDirty(db, 'accounts'); // known
    await _seedDirty(db, 'mystery_legacy_marker'); // unknown
    final unsupported = await unsupportedDirtyMarkers(db);
    expect(unsupported, {'mystery_legacy_marker'});
  });
}
