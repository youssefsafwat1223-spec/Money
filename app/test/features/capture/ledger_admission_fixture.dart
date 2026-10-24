import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:drift/drift.dart' show QueryExecutor, QueryExecutorUser, SqlDialect, BatchedStatements, TransactionExecutor;
import 'package:drift/native.dart';
import 'package:money_companion/core/session/account_fence_authority.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/creation_policy.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/replica_location.dart';
import 'package:money_companion/data/db/sql_value_codec.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/session/f2_fixture.dart';

/// Unit fixtures obtain ONLY the database actually admitted by the real host.
/// Persistence is the normal recording platform; authority decisions are real.
class LedgerAdmissionFixture {
  LedgerAdmissionFixture._(this.fixture, this._restore, this.uid);
  final F2Fixture fixture;
  final void Function() _restore;
  final String uid;
  final List<AppDatabase> _databases = [];
  final List<SupabaseClient> _clients = [];
  late AppDatabase _database;
  bool _finished = false;
  static LedgerAdmissionFixture? _active;

  static SupabaseClient trackClient(SupabaseClient client) {
    final fixture = _active;
    if (fixture == null) throw StateError('ledger_fixture_client_without_owner');
    fixture._clients.add(client);
    return client;
  }

  AppDatabase get database => _database;
  ReplicaLocation get location => fixture.host.current!.location!;

  static Future<LedgerAdmissionFixture> open([String uid = 'user-1', LedgerDatabaseProbe? probe]) async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final restore = AccountFenceAuthority.replacePersistenceForTest();
    final fixture = await F2Fixture.create(afterWithdraw: () async {},
        opener: probe == null ? null : ({location, runMigrations = true,
          creation = const CreationPolicy.unrestricted()}) async {
      final key = await SecureDatabaseKeyStore(storageKey: location!.keyName,
          databaseExists: () => File(location.dbPath).exists(),
          creation: creation).readOrCreateKey();
      final executor = probe.attached ? LedgerDatabaseProbe() : probe;
      executor.attached = true;
      executor.delegate = NativeDatabase(File(location.dbPath), enableMigrations: false,
          setup: (database) {
        database.execute("PRAGMA cipher = 'sqlcipher';");
        if (database.select('PRAGMA cipher;').isEmpty) {
          throw StateError('ledger fixture encryption unavailable');
        }
        database.execute('PRAGMA key = ${sqlString(key)};');
        database.select('SELECT count(*) FROM sqlite_master;');
        database.execute('PRAGMA foreign_keys = ON;');
      });
      return AppDatabase.open(executor: executor, location: location,
          runMigrations: runMigrations, creation: creation);
    });
    fixture.session.configureAccountScope(fixture.host);
    final result = LedgerAdmissionFixture._(fixture, restore, uid);
    _active = result;
    fixture.host.addListener(result._rememberDatabase);
    result._rememberDatabase();
    await fixture.signIn(uid);
    result._database = fixture.host.current!.database;
    expect(await AccountFenceAuthority.shared.capture(fixture.session, fixture.host),
        isNotNull);
    return result;
  }

  void _rememberDatabase() {
    final db = fixture.host.current?.database;
    if (db != null && !_databases.contains(db)) _databases.add(db);
  }

  SupabaseClient ownClient(SupabaseClient client) {
    _clients.add(client);
    return client;
  }

  /// A new coherent lifetime on the SAME actual persisted replica/key.
  Future<AppDatabase> restart() async {
    await fixture.session.drainAdmissions();
    final old = _database;
    await fixture.restart();
    expect(old.lifecycleState, DatabaseLifecycleState.closed);
    fixture.session.configureAccountScope(fixture.host);
    fixture.host.addListener(_rememberDatabase);
    _rememberDatabase();
    await fixture.signIn(uid);
    _database = fixture.host.current!.database;
    return _database;
  }

  /// Privileged test inspection only, never attached/published/admitted.
  static Future<T> inspectClosed<T>(AppDatabase original, ReplicaLocation location,
      Future<T> Function(AppDatabase) read) async {
    expect(original.lifecycleState, DatabaseLifecycleState.closed);
    expect(File(location.dbPath).existsSync(), isTrue);
    expect(await SecureDatabaseKeyStore(storageKey: location.keyName,
        databaseExists: () => File(location.dbPath).exists()).readStoredKey(), isNotNull);
    final inspection = await AppDatabase.open(location: location,
        runMigrations: false, creation: const CreationPolicy.denied());
    try {
      return await read(inspection);
    } finally {
      await inspection.close();
      expect(inspection.lifecycleState, DatabaseLifecycleState.closed);
    }
  }

  Future<void> finish() async {
    if (_finished) return;
    await fixture.session.drainAdmissions();
    for (final client in _clients) {
      await client.dispose();
    }
    await fixture.dispose();
    for (final db in _databases) {
      expect(db.lifecycleState, DatabaseLifecycleState.closed);
    }
    expect(await AccountFenceAuthority.shared.initialize(), isTrue);
    expect(AccountFenceAuthority.shared.store.ready, isTrue);
    _restore();
    if (identical(_active, this)) _active = null;
    _finished = true;
  }
}


/// Actual executor boundary: controlled waits/failures never fabricate authority.
class LedgerDatabaseProbe extends QueryExecutor {
  late QueryExecutor delegate;
  bool attached = false;
  final transactionStatements = <String>[];
  Future<void> Function(String sql)? before;
  Future<void> Function(String sql)? afterSelect;
  Future<void> Function()? afterTransactionOpen;
  void Function()? afterTransactionSend;
  void Function()? onClose;
  void Function()? onClosed;
  void Function()? afterTransactionSettled;
  bool failClose = false;
  int closeAttempts = 0;
  Future<void> _before(String sql) async => await before?.call(sql);
  @override
  SqlDialect get dialect => delegate.dialect;
  @override
  Future<bool> ensureOpen(QueryExecutorUser user) => delegate.ensureOpen(user);
  @override
  Future<List<Map<String, Object?>>> runSelect(String sql, List<Object?> args) async {
    await _before(sql); final rows = await delegate.runSelect(sql, args); await afterSelect?.call(sql); return rows;
  }
  @override
  Future<int> runInsert(String sql, List<Object?> args) async {
    await _before(sql); return delegate.runInsert(sql, args);
  }
  @override
  Future<int> runUpdate(String sql, List<Object?> args) async {
    await _before(sql); return delegate.runUpdate(sql, args);
  }
  @override
  Future<int> runDelete(String sql, List<Object?> args) async {
    await _before(sql); return delegate.runDelete(sql, args);
  }
  @override
  Future<void> runCustom(String sql, [List<Object?>? args]) async {
    await _before(sql); return delegate.runCustom(sql, args);
  }
  @override
  Future<void> runBatched(BatchedStatements statements) => delegate.runBatched(statements);
  @override
  TransactionExecutor beginTransaction() => _LedgerTransactionProbe(delegate.beginTransaction(), (sql) async { transactionStatements.add(sql); await _before(sql); }, () => afterTransactionOpen?.call(), () => afterTransactionSend?.call(), () => afterTransactionSettled?.call());
  @override
  QueryExecutor beginExclusive() {
    final exclusive = LedgerDatabaseProbe();
    exclusive.delegate = delegate.beginExclusive();
    exclusive.before = _before;
    exclusive.afterTransactionOpen = afterTransactionOpen;
    exclusive.afterTransactionSend = afterTransactionSend;
    return exclusive;
  }
  @override
  Future<void> close() async {
    closeAttempts++;
    onClose?.call();
    if (failClose) throw StateError('ledger executor close failure');
    await delegate.close();
    onClosed?.call();
  }
}


class _LedgerTransactionProbe extends TransactionExecutor {
  _LedgerTransactionProbe(this.delegate, this.before, this.afterOpen, this.afterSend, this.afterSettled);
  final TransactionExecutor delegate;
  final Future<void> Function(String) before;
  final Future<void>? Function() afterOpen;
  final void Function() afterSend;
  final void Function() afterSettled;
  @override
  bool get supportsNestedTransactions => delegate.supportsNestedTransactions;
  @override
  SqlDialect get dialect => delegate.dialect;
  @override
  Future<bool> ensureOpen(QueryExecutorUser user) async {
    final opened = await delegate.ensureOpen(user);
    await afterOpen();
    return opened;
  }
  @override
  Future<List<Map<String, Object?>>> runSelect(String sql, List<Object?> args) async {
    await before(sql); return delegate.runSelect(sql, args);
  }
  @override
  Future<int> runInsert(String sql, List<Object?> args) async {
    await before(sql); return delegate.runInsert(sql, args);
  }
  @override
  Future<int> runUpdate(String sql, List<Object?> args) async {
    await before(sql); return delegate.runUpdate(sql, args);
  }
  @override
  Future<int> runDelete(String sql, List<Object?> args) async {
    await before(sql); return delegate.runDelete(sql, args);
  }
  @override
  Future<void> runCustom(String sql, [List<Object?>? args]) async {
    await before(sql); return delegate.runCustom(sql, args);
  }
  @override
  Future<void> runBatched(BatchedStatements statements) async {
    for (final sql in statements.statements) { await before(sql); }
    await delegate.runBatched(statements);
  }
  @override
  TransactionExecutor beginTransaction() => _LedgerTransactionProbe(delegate.beginTransaction(), before, afterOpen, afterSend, afterSettled);
  @override
  QueryExecutor beginExclusive() => throw UnsupportedError('exclusive inside transaction');
  @override
  Future<void> send() async { await delegate.send(); afterSend(); afterSettled(); }
  @override
  Future<void> rollback() async { await delegate.rollback(); afterSettled(); }
  @override
  Future<void> close() => delegate.close();
}
