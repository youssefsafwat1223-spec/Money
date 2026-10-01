import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/catalog/catalog_daos.dart';
import 'package:money_companion/data/catalog/feature_flag_service.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

/// Awaitable stand-in for `client.from(t).select().eq()` returning [rows].
class _FakeBuilder implements PostgrestFilterBuilder<PostgrestList> {
  _FakeBuilder(this.rows);
  final PostgrestList rows;

  @override
  PostgrestFilterBuilder<PostgrestList> select([String columns = '*']) => this;

  @override
  PostgrestFilterBuilder<PostgrestList> eq(String column, Object value) => this;

  @override
  Future<R> then<R>(FutureOr<R> Function(PostgrestList) onValue,
          {Function? onError}) =>
      Future<PostgrestList>.value(rows).then(onValue, onError: onError);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeClient implements SupabaseClient {
  _FakeClient(this.rows);
  final PostgrestList rows;

  @override
  SupabaseQueryBuilder from(String table) => _FakeQuery(rows);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeQuery implements SupabaseQueryBuilder {
  _FakeQuery(this.rows);
  final PostgrestList rows;

  @override
  PostgrestFilterBuilder<PostgrestList> select([String columns = '*']) =>
      _FakeBuilder(rows);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
      'applyUserOverrides ignores enable_proof_autocommit and ai_sender_mapping_auto',
      () async {
    final db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    addTearDown(db.close);
    final svc =
        FeatureFlagService(dao: RemoteFeatureFlagsDao(db), installId: 'test');
    await svc.init();

    await svc.applyUserOverrides(
      _FakeClient([
        {'key': 'enable_proof_autocommit', 'enabled': true},
        {'key': 'ai_sender_mapping_auto', 'enabled': true},
        {'key': 'enable_coupons', 'enabled': true},
      ]),
      'user-1',
    );

    expect(svc.getBool('enable_proof_autocommit'), isFalse);
    expect(svc.getBool('ai_sender_mapping_auto'), isFalse);
    expect(
        svc.getBool('enable_coupons'), isTrue); // other overrides still apply
  });
}
