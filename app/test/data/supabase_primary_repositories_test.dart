import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:money_companion/data/catalog/catalog_daos.dart';
import 'package:money_companion/data/catalog/feature_flag_service.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/financial_cache_health.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/data/repositories/routed_transaction_repository.dart';
import 'package:money_companion/data/repositories/supabase_account_repository.dart';
import 'package:money_companion/data/repositories/supabase_financial_summary_service.dart';
import 'package:money_companion/data/repositories/supabase_transaction_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/errors/repo_exceptions.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';

  @override
  Future<String?> readStoredKey() async => 'test-key';
}

Future<AppDatabase> _openDb() {
  return AppDatabase.open(
    executor: NativeDatabase.memory(),
    keyStore: _MemoryKeyStore(),
  );
}

SupabaseClient _client(MockClient http) {
  return SupabaseClient(
    'https://example.supabase.co',
    'public-anon-key',
    httpClient: http,
    accessToken: () async => 'qa-access-token',
  );
}

Map<String, dynamic> _serverTransaction({
  required String id,
  double amount = 25,
  String status = 'confirmed',
  String source = 'manual',
  DateTime? occurredAt,
}) {
  final at = occurredAt ?? DateTime.utc(2026, 7, 13, 10);
  return {
    'id': id,
    'user_id': 'qa-user',
    'source_payload_id': null,
    'local_account_id': null,
    'server_account_id': null,
    'client_request_id': id,
    'amount': amount,
    'currency': 'EGP',
    'direction': 'debit',
    'transaction_type': 'expense',
    'merchant': 'Test Merchant',
    'description': null,
    'category_id': null,
    'occurred_at': at.toIso8601String(),
    'source': source,
    'confidence': 1.0,
    'raw_hash': null,
    'balance_after': null,
    'status': status,
    'foreign_amount': null,
    'foreign_currency': null,
    'comparison_timestamp': at.toIso8601String(),
    'comparison_timestamp_source': 'received_at',
    'metadata': {'transaction_source': 'unknown'},
    'created_at': at.toIso8601String(),
    'updated_at': at.toIso8601String(),
    'deleted_at': null,
  };
}

TransactionEntity _localTransaction({String id = 'stable-request-id'}) {
  final at = DateTime.utc(2026, 7, 13, 10);
  return TransactionEntity(
    id: id,
    amount: 25,
    currency: 'EGP',
    type: TransactionTypeEntity.payment,
    source: TransactionSourceEntity.unknown,
    occurredAt: at,
    rawMessage: 'sensitive bank text that must stay local',
    parseConfidence: 1,
    status: TransactionStatus.pending,
    createdAt: at,
    updatedAt: at,
    direction: TransactionDirectionEntity.debit,
    comparisonTimestamp: at,
  );
}

Map<String, dynamic> _serverAccount({
  required String id,
  String localId = 'local-account',
  bool isDefault = false,
}) {
  final at = DateTime.utc(2026, 7, 13, 9);
  return {
    'id': id,
    'user_id': 'qa-user',
    'local_id': localId,
    'name': 'Main account',
    'currency': 'EGP',
    'type': 'bank',
    'initial_balance': 100,
    'current_balance': 100,
    'is_default': isDefault,
    'sort_order': 1,
    'metadata': <String, dynamic>{},
    'created_at': at.toIso8601String(),
    'updated_at': at.toIso8601String(),
    'deleted_at': null,
  };
}

AccountEntity _localAccount({String id = 'local-account'}) {
  final at = DateTime.utc(2026, 7, 13, 9);
  return AccountEntity(
    id: id,
    name: 'Main account',
    currency: 'EGP',
    type: AccountType.bank,
    initialBalance: 100,
    currentBalance: 100,
    isDefault: false,
    sortOrder: 1,
    createdAt: at,
    updatedAt: at,
  );
}

Response _json(Object body, BaseRequest request, {int status = 200}) {
  return Response(
    jsonEncode(body),
    status,
    headers: const {
      'content-type': 'application/json',
      'content-range': '0-0/*',
    },
    request: request,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SupabaseTransactionRepository', () {
    late AppDatabase db;

    setUp(() async {
      db = await _openDb();
    });

    tearDown(() async {
      await db.close();
    });

    test('create is server-first, stable, pending-aware, and excludes raw SMS',
        () async {
      Map<String, dynamic>? sentBody;
      final http = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/rest/v1/user_transactions');
        final decoded = jsonDecode(request.body);
        sentBody = Map<String, dynamic>.from(
          decoded is List ? decoded.single as Map : decoded as Map,
        );
        return _json(
          _serverTransaction(id: 'server-tx-1', status: 'pending'),
          request,
        );
      });
      final repository = SupabaseTransactionRepository(
        db: db,
        getClient: () => _client(http),
        getAuthUserId: () async => 'qa-user',
      );

      final saved = await repository.saveTransaction(
        transaction: _localTransaction(),
        categoryKey: null,
      );

      expect(sentBody?['client_request_id'], 'stable-request-id');
      expect(sentBody?['status'], 'pending');
      expect(sentBody?['source'], 'manual');
      expect(sentBody?.containsKey('raw_message'), isFalse);
      expect(jsonEncode(sentBody), isNot(contains('sensitive bank text')));
      expect(saved.id, 'server-tx-1');
      expect(saved.status, TransactionStatus.pending);

      final mirrored = await db
          .customSelect(
            "SELECT status, server_id FROM transactions WHERE id = 'stable-request-id';",
          )
          .getSingle();
      expect(mirrored.read<String>('status'), 'pending');
      expect(mirrored.read<String>('server_id'), 'server-tx-1');
    });

    test('duplicate client_request_id fetches existing row without overwrite',
        () async {
      var calls = 0;
      final existing = _serverTransaction(id: 'server-existing', amount: 99);
      final http = MockClient((request) async {
        calls++;
        if (request.method == 'POST') {
          return _json(
            {
              'code': '23505',
              'message': 'duplicate key',
              'details': null,
              'hint': null,
            },
            request,
            status: 409,
          );
        }
        expect(request.method, 'GET');
        return _json(existing, request);
      });
      final repository = SupabaseTransactionRepository(
        db: db,
        getClient: () => _client(http),
        getAuthUserId: () async => 'qa-user',
      );

      final saved = await repository.saveTransaction(
        transaction: _localTransaction(),
        categoryKey: null,
      );

      expect(calls, 2);
      expect(saved.id, 'server-existing');
      expect(saved.amount, 99);
    });

    test('getAll paginates beyond PostgREST 1000 row default', () async {
      var requests = 0;
      final http = MockClient((request) async {
        requests++;
        final start = int.tryParse(
              request.url.queryParameters['offset'] ?? '',
            ) ??
            0;
        final limit = int.tryParse(
              request.url.queryParameters['limit'] ?? '',
            ) ??
            500;
        final end = start + limit - 1;
        final rows = <Map<String, dynamic>>[];
        for (var index = start; index <= end && index < 1200; index++) {
          rows.add(_serverTransaction(
            id: 'server-$index',
            occurredAt: DateTime.utc(2026, 1, 1).add(Duration(minutes: index)),
          ));
        }
        return _json(rows, request);
      });
      final repository = SupabaseTransactionRepository(
        db: db,
        getClient: () => _client(http),
        getAuthUserId: () async => 'qa-user',
      );

      final rows = await repository.getAll();

      expect(rows, hasLength(1200));
      expect(requests, 3);
      expect(rows.first.id, 'server-1199');
      expect(rows.last.id, 'server-0');
    });

    test('date queries use a half-open UTC range', () async {
      Uri? requested;
      final http = MockClient((request) async {
        requested = request.url;
        return _json(<Object>[], request);
      });
      final repository = SupabaseTransactionRepository(
        db: db,
        getClient: () => _client(http),
        getAuthUserId: () async => 'qa-user',
      );
      final from = DateTime.utc(2026, 7, 1);
      final to = DateTime.utc(2026, 8, 1);

      expect(
        await repository.expenseTotalBetween(from: from, to: to),
        0,
      );

      final decoded = Uri.decodeQueryComponent(requested!.query);
      expect(decoded, contains('occurred_at=gte.${from.toIso8601String()}'));
      expect(decoded, contains('occurred_at=lt.${to.toIso8601String()}'));
      expect(decoded, isNot(contains('occurred_at=lte.')));
    });

    test('network failure throws and does not create a local financial row',
        () async {
      final http = MockClient((_) async => throw ClientException('network'));
      final repository = SupabaseTransactionRepository(
        db: db,
        getClient: () => _client(http),
        getAuthUserId: () async => 'qa-user',
      );

      await expectLater(
        repository.saveTransaction(
          transaction: _localTransaction(),
          categoryKey: null,
        ),
        throwsA(isA<NetworkRepoException>()),
      );
      final count = await db
          .customSelect(
            'SELECT COUNT(*) AS total FROM transactions;',
          )
          .getSingle();
      expect(count.read<int>('total'), 0);
    });

    test('missing auth fails before any network request', () async {
      var called = false;
      final http = MockClient((request) async {
        called = true;
        return _json(<Object>[], request);
      });
      final repository = SupabaseTransactionRepository(
        db: db,
        getClient: () => _client(http),
        getAuthUserId: () async => null,
      );

      await expectLater(repository.getAll(), throwsA(isA<AuthRepoException>()));
      expect(called, isFalse);
    });
  });

  group('SupabaseAccountRepository', () {
    late AppDatabase db;

    setUp(() async {
      db = await _openDb();
    });

    tearDown(() async {
      await db.close();
    });

    test('create uses stable local_id then mirrors only after server success',
        () async {
      Map<String, dynamic>? sentBody;
      final http = MockClient((request) async {
        if (request.method == 'POST') {
          final decoded = jsonDecode(request.body);
          sentBody = Map<String, dynamic>.from(
            decoded is List ? decoded.single as Map : decoded as Map,
          );
          return _json(_serverAccount(id: 'server-account'), request);
        }
        return _json([
          {'id': 'server-account'},
          {'id': 'another-account'},
        ], request);
      });
      final repository = SupabaseAccountRepository(
        db: db,
        getClient: () => _client(http),
        getAuthUserId: () async => 'qa-user',
      );

      final saved = await repository.create(_localAccount());

      expect(sentBody?['local_id'], 'local-account');
      expect(saved.id, 'server-account');
      final mirrored = await db
          .customSelect(
            "SELECT server_id FROM accounts WHERE id = 'local-account';",
          )
          .getSingle();
      expect(mirrored.read<String>('server_id'), 'server-account');
    });

    test('failed create does not create a permanent local account', () async {
      final before = await db
          .customSelect('SELECT COUNT(*) AS total FROM accounts;')
          .getSingle();
      final http = MockClient((_) async => throw ClientException('network'));
      final repository = SupabaseAccountRepository(
        db: db,
        getClient: () => _client(http),
        getAuthUserId: () async => 'qa-user',
      );

      await expectLater(
        repository.create(_localAccount()),
        throwsA(isA<NetworkRepoException>()),
      );
      final count = await db
          .customSelect(
            'SELECT COUNT(*) AS total FROM accounts;',
          )
          .getSingle();
      expect(count.read<int>('total'), before.read<int>('total'));
    });

    test('setDefault mirrors all cached default states atomically', () async {
      final now = DateTime.utc(2026, 7, 13).toIso8601String();
      await db.customStatement('''
        INSERT INTO accounts(
          id, name, currency, type, is_default, sort_order,
          created_at, updated_at, server_id, sync_status
        ) VALUES
          ('local-a', 'A', 'EGP', 'bank', 1, 0, ?, ?, 'server-a', 'synced'),
          ('local-b', 'B', 'EGP', 'bank', 0, 1, ?, ?, 'server-b', 'synced');
      ''', [now, now, now, now]);
      final selected = _serverAccount(
        id: 'server-b',
        localId: 'local-b',
        isDefault: true,
      );
      final http = MockClient((request) async => _json(selected, request));
      final repository = SupabaseAccountRepository(
        db: db,
        getClient: () => _client(http),
        getAuthUserId: () async => 'qa-user',
      );

      await repository.setDefault('server-b');

      final rows = await db
          .customSelect(
            "SELECT id, is_default FROM accounts WHERE id IN ('local-a', 'local-b') ORDER BY id;",
          )
          .get();
      expect(
        rows
            .singleWhere((row) => row.read<String>('id') == 'local-a')
            .read<int>('is_default'),
        0,
      );
      expect(
        rows
            .singleWhere((row) => row.read<String>('id') == 'local-b')
            .read<int>('is_default'),
        1,
      );
    });
  });

  group('SupabaseFinancialSummaryService', () {
    test('maps explicit expense, income, refund, and transfer totals',
        () async {
      Map<String, dynamic>? sentBody;
      final http = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/rest/v1/rpc/monthly_financial_summary');
        sentBody = Map<String, dynamic>.from(jsonDecode(request.body) as Map);
        return _json(
          {
            'expense': 200.5,
            'income': 1000,
            'refund': 25,
            'transfer': 300,
          },
          request,
        );
      });
      final service = SupabaseFinancialSummaryService(
        getClient: () => _client(http),
        getAuthUserId: () async => 'qa-user',
      );

      final summary = await service.periodSummary(
        from: DateTime.utc(2026, 6, 30, 22),
        to: DateTime.utc(2026, 7, 31, 22),
        accountId: 'server-account',
      );

      expect(summary.expense, 200.5);
      expect(summary.income, 1000);
      expect(summary.refund, 25);
      expect(summary.transfer, 300);
      expect(sentBody?['p_from_inclusive'], '2026-06-30T22:00:00.000Z');
      expect(sentBody?['p_to_exclusive'], '2026-07-31T22:00:00.000Z');
      expect(sentBody?['p_account_id'], 'server-account');
    });

    test('maps category RPC rows without downloading transactions', () async {
      final http = MockClient((request) async {
        expect(request.url.path, '/rest/v1/rpc/category_spending_summary');
        return _json(
          [
            {
              'category_id': 'groceries',
              'total': 150.25,
              'transaction_count': 1201,
            }
          ],
          request,
        );
      });
      final service = SupabaseFinancialSummaryService(
        getClient: () => _client(http),
        getAuthUserId: () async => 'qa-user',
      );

      final rows = await service.categorySummary(
        from: DateTime.utc(2026, 7),
        to: DateTime.utc(2026, 8),
      );

      expect(rows, hasLength(1));
      expect(rows.single.categoryId, 'groceries');
      expect(rows.single.total, 150.25);
      expect(rows.single.count, 1201);
    });

    test('requires auth before invoking a summary RPC', () async {
      var called = false;
      final service = SupabaseFinancialSummaryService(
        getClient: () => _client(MockClient((request) async {
          called = true;
          return _json(<String, Object>{}, request);
        })),
        getAuthUserId: () async => null,
      );

      await expectLater(
        service.periodSummary(
          from: DateTime.utc(2026, 7),
          to: DateTime.utc(2026, 8),
        ),
        throwsA(isA<AuthRepoException>()),
      );
      expect(called, isFalse);
    });
  });

  group('financial cache rollback safety', () {
    late AppDatabase db;

    setUp(() async {
      db = await _openDb();
    });

    tearDown(() async {
      await db.close();
    });

    test('dirty cache blocks Drift fallback until repair clears it', () async {
      var driftCalled = false;
      await markFinancialCacheDirty(db, accountsCacheEntityType, 'mirror');

      await expectLater(
        routeFinancialOperation<int>(
          db: db,
          entityType: accountsCacheEntityType,
          useSupabase: false,
          supabase: () async => 1,
          drift: () async {
            driftCalled = true;
            return 2;
          },
        ),
        throwsA(
          isA<ServerRepoException>().having(
            (error) => error.message,
            'message',
            'financial_cache_dirty',
          ),
        ),
      );
      expect(driftCalled, isFalse);

      await clearFinancialCacheDirty(db, accountsCacheEntityType);
      expect(
        await routeFinancialOperation<int>(
          db: db,
          entityType: accountsCacheEntityType,
          useSupabase: false,
          supabase: () async => 1,
          drift: () async => 2,
        ),
        2,
      );
    });

    test('authoritative Supabase path bypasses dirty rollback cache', () async {
      await markFinancialCacheDirty(db, accountsCacheEntityType, 'mirror');

      expect(
        await routeFinancialOperation<int>(
          db: db,
          entityType: accountsCacheEntityType,
          useSupabase: true,
          supabase: () async => 1,
          drift: () async => 2,
        ),
        1,
      );
    });

    test('a later successful mirror does not clear an older dirty marker',
        () async {
      await markFinancialCacheDirty(db, accountsCacheEntityType, 'mirror');
      await mirrorFinancialCacheSafely(
        db,
        accountsCacheEntityType,
        () async {},
      );

      expect(
        await isFinancialCacheDirty(db, accountsCacheEntityType),
        isTrue,
      );
    });

    test('transaction primary never falls back when account primary is off',
        () async {
      final now = DateTime.utc(2026, 7, 13);
      await RemoteFeatureFlagsDao(db).replaceAll([
        RemoteFeatureFlag(
          key: 'transactions_supabase_primary',
          valueType: 'boolean',
          value: 'true',
          rolloutPercent: 100,
          targetCountries: const [],
          isActive: true,
          syncedAt: now,
        ),
      ]);
      final flags = FeatureFlagService(
        dao: RemoteFeatureFlagsDao(db),
        installId: 'test-install',
      );
      await flags.init();
      final repository = RoutedTransactionRepository(
        db: db,
        drift: DriftTransactionRepository(db),
        supabase: SupabaseTransactionRepository(db: db),
        flags: () => flags,
      );

      await expectLater(
        repository.getAll(),
        throwsA(
          isA<ServerRepoException>().having(
            (error) => error.message,
            'message',
            'accounts_primary_required',
          ),
        ),
      );
    });
  });
}
