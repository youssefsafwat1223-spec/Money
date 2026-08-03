import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';

  @override
  Future<String?> readStoredKey() async => 'test-key';
}

Future<AppDatabase> _openDb() => AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );

/// Raw effective-grant flags + versioned state, straight from the DB.
Future<({int ai, int cloud, String? aiState, String? cloudState})> _raw(
  AppDatabase db,
) async {
  final row = await db.customSelect('''
    SELECT ai_consent_granted, cloud_processing_enabled,
           ai_consent_state, cloud_consent_state
    FROM user_settings LIMIT 1;
  ''').getSingle();
  return (
    ai: row.read<int>('ai_consent_granted'),
    cloud: row.read<int>('cloud_processing_enabled'),
    aiState: row.readNullable<String>('ai_consent_state'),
    cloudState: row.readNullable<String>('cloud_consent_state'),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // MALI-059n (approved): cloud + AI processing default OFF; separate explicit
  // opt-ins; never inferred from onboarding/auth/restore/migration/previous
  // default; existing installs with no explicit choice migrate to OFF;
  // revocation is immediate + fail-closed. A versioned tri-state distinguishes
  // unset / accepted / declined (not a default-true boolean).

  test('fresh install defaults BOTH cloud and AI processing to OFF/unset',
      () async {
    final db = await _openDb();
    addTearDown(db.close);

    final raw = await _raw(db);
    expect((raw.ai, raw.cloud), (0, 0), reason: 'effective grant OFF');
    expect(raw.aiState, isNull, reason: 'unset, not an explicit choice');
    expect(raw.cloudState, isNull);

    final settings = await DriftUserSettingsRepository(db).getSettings();
    expect(settings.aiConsentGranted, isFalse);
    expect(settings.cloudProcessingEnabled, isFalse);
    expect(settings.aiConsentState, ConsentState.unset);
    expect(settings.cloudConsentState, ConsentState.unset);
  });

  test('an existing default-ON install with no explicit choice migrates to OFF',
      () async {
    final db = await _openDb();
    addTearDown(db.close);
    // Simulate a legacy row: effective grant ON but the versioned state never
    // recorded (the pre-MALI-059n default-true world).
    await db.customStatement('''
      UPDATE user_settings
      SET ai_consent_granted = 1, cloud_processing_enabled = 1,
          ai_consent_state = NULL, cloud_consent_state = NULL;
    ''');

    await db.debugReinitialize(); // runs the migrate-to-OFF backfill

    final raw = await _raw(db);
    expect((raw.ai, raw.cloud), (0, 0),
        reason: 'no explicit choice → migrate to OFF');
    expect(raw.aiState, isNull);
    expect(raw.cloudState, isNull);
  });

  test('an explicit choice is never coerced by re-initialization', () async {
    final db = await _openDb();
    addTearDown(db.close);
    await db.customStatement('''
      UPDATE user_settings
      SET ai_consent_granted = 1, cloud_processing_enabled = 1,
          ai_consent_state = 'accepted', cloud_consent_state = 'accepted';
    ''');

    await db.debugReinitialize();

    final raw = await _raw(db);
    expect((raw.ai, raw.cloud), (1, 1), reason: 'explicit accept survives');
    expect(raw.aiState, 'accepted');
    expect(raw.cloudState, 'accepted');
  });

  test('the repository persists the explicit tri-state choice (accept/decline)',
      () async {
    final db = await _openDb();
    addTearDown(db.close);
    final repo = DriftUserSettingsRepository(db);
    final current = await repo.getSettings();

    final accepted = await repo.saveSettings(current.copyWith(
      cloudConsentState: ConsentState.accepted,
      aiConsentState: ConsentState.declined,
    ));
    expect(accepted.cloudProcessingEnabled, isTrue);
    expect(accepted.aiConsentGranted, isFalse, reason: 'declined ≠ accepted');
    var raw = await _raw(db);
    expect((raw.ai, raw.cloud), (0, 1));
    expect(raw.aiState, 'declined');
    expect(raw.cloudState, 'accepted');

    // Revocation is immediate: reading back reflects the declined state.
    final revoked = await repo.saveSettings(
      accepted.copyWith(cloudConsentState: ConsentState.declined),
    );
    expect(revoked.cloudProcessingEnabled, isFalse);
    raw = await _raw(db);
    expect(raw.cloud, 0);
    expect(raw.cloudState, 'declined');
  });

  test('restore does NOT import consent — it resets to unset/OFF', () async {
    final db = await _openDb();
    addTearDown(db.close);
    // A restored backup somehow carrying an accepted consent (legacy format).
    await db.customStatement('''
      UPDATE user_settings
      SET ai_consent_granted = 1, cloud_processing_enabled = 1,
          ai_consent_state = 'accepted', cloud_consent_state = 'accepted';
    ''');

    await db.runPostRestoreSetup();

    final raw = await _raw(db);
    expect((raw.ai, raw.cloud), (0, 0),
        reason: 'a new device must re-consent, not inherit authorization');
    expect(raw.aiState, isNull);
    expect(raw.cloudState, isNull);
  });
}
