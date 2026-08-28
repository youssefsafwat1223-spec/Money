import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/features/capture/services/ledger_push_service.dart';
import 'package:money_companion/features/planning_sync/services/accounts_push_service.dart';
import 'package:money_companion/features/planning_sync/services/outbox_queue_factory.dart';

/// C-3 / F-025 — the headline of the finding.
///
/// The privacy screen states «إيقافها يعطّل الالتقاط التلقائي والمزامنة»
/// ("turning it off disables automatic capture and synchronisation"). It did
/// not: with cloud consent OFF and a signed-in user, the push services still
/// uploaded accounts and transactions — the user's money.
///
/// Both services are gated at their `push()` entry, before any auth lookup or
/// outbox read, so nothing about the queue's state can route around it.
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

  group('accounts push', () {
    test('consent OFF: push is refused before it can reach auth or the outbox',
        () async {
      var authLookups = 0;
      final service = AccountsPushService(
        db: db,
        queue: buildPlanningOutboxQueue(db),
        isEnabled: () => true,
        getAuthUserId: () async {
          authLookups++;
          return 'user-1';
        },
        mayEgress: () async => false,
      );

      final result = await service.push();

      expect(result.pushed, 0);
      expect(authLookups, 0,
          reason: 'the gate must come first — a denied push should not even '
              'resolve the session');
    });

    test('a caller that omits the gate gets NO network', () async {
      var authLookups = 0;
      final service = AccountsPushService(
        db: db,
        queue: buildPlanningOutboxQueue(db),
        isEnabled: () => true,
        getAuthUserId: () async {
          authLookups++;
          return 'user-1';
        },
      );
      await service.push();
      expect(authLookups, 0, reason: 'the default must deny, not permit');
    });
  });

  group('ledger push', () {
    test('consent OFF: push is refused before auth', () async {
      var authLookups = 0;
      final service = LedgerPushService(
        db: db,
        queue: buildLedgerOutboxQueue(db),
        isPushEnabled: () => true,
        getAuthUserId: () async {
          authLookups++;
          return 'user-1';
        },
        mayEgress: () async => false,
      );

      final result = await service.push();

      expect(result.pushed, 0);
      expect(authLookups, 0);
    });

    test('a caller that omits the gate gets NO network', () async {
      var authLookups = 0;
      final service = LedgerPushService(
        db: db,
        queue: buildLedgerOutboxQueue(db),
        isPushEnabled: () => true,
        getAuthUserId: () async {
          authLookups++;
          return 'user-1';
        },
      );
      await service.push();
      expect(authLookups, 0);
    });
  });

  test('consent ON: the gate does not break the feature', () async {
    var authLookups = 0;
    final service = AccountsPushService(
      db: db,
      queue: buildPlanningOutboxQueue(db),
      isEnabled: () => true,
      getAuthUserId: () async {
        authLookups++;
        return 'user-1';
      },
      mayEgress: () async => true,
    );
    await service.push();
    expect(authLookups, greaterThan(0),
        reason: 'with consent granted the push proceeds past the gate');
  });

  test('revocation is observed by the NEXT push, not the next boot', () async {
    var consent = true;
    var authLookups = 0;
    final service = AccountsPushService(
      db: db,
      queue: buildPlanningOutboxQueue(db),
      isEnabled: () => true,
      getAuthUserId: () async {
        authLookups++;
        return 'user-1';
      },
      mayEgress: () async => consent,
    );

    await service.push();
    final afterGranted = authLookups;
    expect(afterGranted, greaterThan(0));

    consent = false;
    await service.push();
    expect(authLookups, afterGranted,
        reason: 'a queued drain must observe revocation at egress time');
  });
}
