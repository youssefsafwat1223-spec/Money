import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';

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

Future<(int, int)> _rawProcessingFlags(AppDatabase db) async {
  final row = await db.customSelect('''
    SELECT ai_consent_granted, cloud_processing_enabled
    FROM user_settings
    LIMIT 1;
  ''').getSingle();
  return (
    row.read<int>('ai_consent_granted'),
    row.read<int>('cloud_processing_enabled'),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('fresh settings enable required cloud and AI processing', () async {
    final db = await _openDb();
    addTearDown(db.close);

    expect(await _rawProcessingFlags(db), (1, 1));
  });

  test('database initialization upgrades former disabled values', () async {
    final db = await _openDb();
    addTearDown(db.close);
    await db.customUpdate('''
      UPDATE user_settings
      SET ai_consent_granted = 0,
          cloud_processing_enabled = 0;
    ''');

    await db.initialize();

    expect(await _rawProcessingFlags(db), (1, 1));
  });

  test('settings repository cannot disable required processing', () async {
    final db = await _openDb();
    addTearDown(db.close);
    final repository = DriftUserSettingsRepository(db);
    final current = await repository.getSettings();

    final saved = await repository.saveSettings(current.copyWith(
      aiConsentGranted: false,
      cloudProcessingEnabled: false,
    ));

    expect(saved.aiConsentGranted, isTrue);
    expect(saved.cloudProcessingEnabled, isTrue);
    expect(await _rawProcessingFlags(db), (1, 1));
  });
}
