import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';
import 'package:money_companion/features/planning_sync/services/planning_startup_registration_service.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('startup registers settings and custom categories exactly once',
      () async {
    final db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    addTearDown(db.close);
    await db.customStatement('''
      INSERT INTO categories(id,key,name_ar,icon,color,is_income,sort_order)
      VALUES ('custom-1','custom_hobby','هواية','star','#123456',0,100);
    ''');
    final queue = PlanningOutboxQueue(
      db: db,
      isSyncEnabled: (_) => true,
      getAuthUserId: () async => 'user-1',
    );
    final service = PlanningStartupRegistrationService(
      db: db,
      queue: queue,
      isEnabled: (_) => true,
    );

    // A COMPLETED pull that found no remote singleton is the only state that
    // authorizes the initial full-row settings CREATE (audit NEW-H-4).
    await service.registerMissingRows(settingsPullCompleted: true);
    await service.registerMissingRows(settingsPullCompleted: true);

    final rows = await db.customSelect('''
      SELECT entity_type, COUNT(*) AS n FROM planning_sync_outbox
      WHERE entity_type IN ('settings','category')
      GROUP BY entity_type ORDER BY entity_type;
    ''').get();
    expect(rows, hasLength(2));
    expect(rows.every((row) => row.read<int>('n') == 1), isTrue);
  });

  test(
      'NEW-H-4: without a completed settings pull, NO full-row settings CREATE '
      'is queued (categories may still register) and retry stays possible',
      () async {
    final db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    addTearDown(db.close);
    await db.customStatement('''
      INSERT INTO categories(id,key,name_ar,icon,color,is_income,sort_order)
      VALUES ('custom-1','custom_hobby','هواية','star','#123456',0,100);
    ''');
    final queue = PlanningOutboxQueue(
      db: db,
      isSyncEnabled: (_) => true,
      getAuthUserId: () async => 'user-1',
    );
    final service = PlanningStartupRegistrationService(
      db: db,
      queue: queue,
      isEnabled: (_) => true,
    );

    // The pull failed/was cancelled → remote settings existence is UNKNOWN.
    await service.registerMissingRows(settingsPullCompleted: false);
    await service.registerMissingRows(settingsPullCompleted: false);

    final settingsQueued = await db.customSelect('''
      SELECT COUNT(*) AS n FROM planning_sync_outbox
      WHERE entity_type = 'settings';
    ''').getSingle();
    expect(settingsQueued.read<int>('n'), 0,
        reason: 'UNKNOWN remote existence must never authorize the full-row '
            'CREATE — it would clobber an existing remote singleton');
    // Categories are keyed by fresh local UUIDs (insert-only) and stay allowed.
    final categoriesQueued = await db.customSelect('''
      SELECT COUNT(*) AS n FROM planning_sync_outbox
      WHERE entity_type = 'category';
    ''').getSingle();
    expect(categoriesQueued.read<int>('n'), 1);

    // A later cycle whose pull completed (and confirmed absence) may register.
    await service.registerMissingRows(settingsPullCompleted: true);
    final afterRetry = await db.customSelect('''
      SELECT COUNT(*) AS n FROM planning_sync_outbox
      WHERE entity_type = 'settings';
    ''').getSingle();
    expect(afterRetry.read<int>('n'), 1,
        reason: 'a blocked registration must stay pending, not be lost');
  });

  test(
      'NEW-H-4 wiring contract: the engine derives the registration authority '
      'from the pull result completedEntities, never from mere pull() return',
      () async {
    // Source-scrape contract (house style — see backend_hardening_contract):
    // the engine must (a) pass settingsPullCompleted into registerMissingRows,
    // (b) derive it from PlanningPullResult.completedEntities for the settings
    // entity, and (c) leave it false when the pull throws (the catch swallows
    // transport errors, so the flag may only be set on the success path).
    final source = File(
      'lib/features/planning_sync/services/planning_sync_engine.dart',
    ).readAsStringSync();
    expect(
      source,
      contains('registerMissingRows(\n'
          '          settingsPullCompleted: settingsPullCompleted)'),
    );
    expect(
      source,
      matches(RegExp(
          r'settingsPullCompleted\s*=\s*result\.completedEntities\s*'
          r'\.contains\(PlanningOutboxQueue\.settingsEntityType\)')),
      reason: 'authority must come from the per-entity completion set',
    );
    final assignIdx = source.indexOf('settingsPullCompleted = result');
    final catchIdx = source.indexOf('planning pull error', assignIdx);
    expect(assignIdx, greaterThan(0));
    expect(catchIdx, greaterThan(assignIdx),
        reason: 'the assignment must sit on the success path before the '
            'swallowing catch — a thrown pull leaves the authority false');
  });
}
