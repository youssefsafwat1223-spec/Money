import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_dedup_store.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/features/capture/services/ledger_sync_service.dart';
import 'package:money_companion/features/planning_sync/services/accounts_pull_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_pull_service.dart';

/// C-3 — the PULL half of the consent finding.
///
/// Push was gated first because uploading the user's money is the obvious
/// violation. Pull is the same promise in the other direction: the privacy
/// screen says turning cloud off «يعطّل … المزامنة» — disables synchronisation —
/// and a download that keeps running is still synchronisation.
///
/// It is also not merely symmetric. A pull WRITES to the local database: it
/// imports server rows, resolves conflicts against local edits, and advances a
/// watermark. So an ungated pull with consent off does not just receive data the
/// user declined — it can overwrite local financial state with it.
///
/// Every gate here sits before the auth lookup and before any cursor read, which
/// is what makes the property hold for retries, resume and startup without each
/// needing its own check: there is no entry into the cursor that bypasses it.
class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

void main() {
  late AppDatabase db;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
  });
  tearDown(() async => db.close());

  group('accounts pull', () {
    test('consent OFF: refused before auth, with the feature fully enabled',
        () async {
      var authLookups = 0;
      final service = AccountsPullService(
        db: db,
        isEnabled: () => true, // feature ON — only consent may stop this
        mayEgress: () async => false,
        getAuthUserId: () async {
          authLookups++;
          return 'user-1';
        },
      );

      final result = await service.pull();

      expect(result.imported, 0);
      expect(result.updated, 0);
      expect(authLookups, 0,
          reason: 'the gate must precede the auth lookup — otherwise a '
              'refused pull still reveals that this install has a session');
    });

    test('consent ON: the pull proceeds to its normal work', () async {
      // Without this the refusal above would also pass on a service that never
      // works at all, which would make the test meaningless.
      var authLookups = 0;
      final service = AccountsPullService(
        db: db,
        isEnabled: () => true,
        mayEgress: () async => true,
        getAuthUserId: () async {
          authLookups++;
          return null; // stop here; reaching auth is the observable we need
        },
      );

      await service.pull();
      expect(authLookups, 1);
    });

    test('a caller that supplies no consent callback gets NO egress', () async {
      // The default is the whole point: consent enforcement was per-service
      // opt-in, so every service that forgot it shipped ungated.
      var authLookups = 0;
      final service = AccountsPullService(
        db: db,
        isEnabled: () => true,
        getAuthUserId: () async {
          authLookups++;
          return 'user-1';
        },
      );

      await service.pull();
      expect(authLookups, 0,
          reason: 'omitting the consent callback must fail CLOSED');
    });
  });

  group('ledger pull', () {
    test('consent OFF: refused before auth', () async {
      var authLookups = 0;
      final service = LedgerSyncService(
        db: db,
        transactionRepository: DriftTransactionRepository(db),
        dedupStore: DriftDedupStore(db),
        isPullEnabled: () => true,
        mayEgress: () async => false,
        getAuthUserId: () async {
          authLookups++;
          return 'user-1';
        },
      );

      final result = await service.pull();
      expect(result.imported, 0);
      expect(authLookups, 0);
    });

    test('omitting the callback fails closed', () async {
      var authLookups = 0;
      final service = LedgerSyncService(
        db: db,
        transactionRepository: DriftTransactionRepository(db),
        dedupStore: DriftDedupStore(db),
        isPullEnabled: () => true,
        getAuthUserId: () async {
          authLookups++;
          return 'user-1';
        },
      );
      await service.pull();
      expect(authLookups, 0);
    });
  });

  group('planning pull', () {
    test('consent OFF: refused before auth, for every entity at once',
        () async {
      var authLookups = 0;
      final service = PlanningPullService(
        db: db,
        isEnabled: (_) => true,
        mayEgress: () async => false,
        getAuthUserId: () async {
          authLookups++;
          return 'user-1';
        },
      );

      final result = await service.pull();
      expect(result.imported, 0);
      expect(authLookups, 0,
          reason: 'the check is per-PULL, not per-entity: a mid-pull '
              'revocation must not leave some entity cursors advanced and '
              'others not');
    });

    test('omitting the callback fails closed', () async {
      var authLookups = 0;
      final service = PlanningPullService(
        db: db,
        isEnabled: (_) => true,
        getAuthUserId: () async {
          authLookups++;
          return 'user-1';
        },
      );
      await service.pull();
      expect(authLookups, 0);
    });
  });

  group('consent is read fresh, never cached', () {
    test('revoking between two pulls stops the second', () async {
      // Restrictive propagation (OD-07) is only real if revocation takes effect
      // immediately. A service that captured the decision at construction would
      // keep pulling for the rest of the session.
      var allowed = true;
      var authLookups = 0;
      final service = AccountsPullService(
        db: db,
        isEnabled: () => true,
        mayEgress: () async => allowed,
        getAuthUserId: () async {
          authLookups++;
          return null;
        },
      );

      await service.pull();
      expect(authLookups, 1, reason: 'first pull ran');

      allowed = false;
      await service.pull();
      expect(authLookups, 1,
          reason: 'the second pull must observe the revocation, not a value '
              'cached at construction');
    });
  });
}
