import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backup/backup_snapshot_builder.dart';
import 'package:money_companion/core/backup/restore_backup_usecase.dart';
import 'package:money_companion/core/session/consent_capability.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';

// A committed consent v3 leaves this device's watermark at 3. A backup restore
// resets consent authorization to unset / v0 (it never imports consent), but the
// device watermark survives: the next choice, even a decline, is above 3, and a
// later explicit enable reserves above that.

class _KeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('restore resets consent to unset/v0 but keeps the watermark; the next '
      'decline and the next reservation stay above it', () async {
    final src = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _KeyStore());
    final dst = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _KeyStore());
    addTearDown(src.close);
    addTearDown(dst.close);
    await src.customStatement(
      "INSERT INTO accounts(id,name,currency,type,initial_balance,current_balance,"
      "credit_limit,available_credit,is_default,sort_order,created_at,updated_at) "
      "VALUES ('acc-x','X','SAR','bank',10,10,NULL,NULL,0,5,"
      "'2026-08-01T00:00:00.000Z','2026-08-01T00:00:00.000Z');",
    );
    await dst.customStatement(
        "INSERT INTO replica_meta(id, owner_uid, replica_id, server_epoch, created_at) "
        "VALUES (1, 'uid-r', 'rep', 0, '2026-01-01T00:00:00Z')");
    final capability = ConsentCapability(
        uid: 'uid-r', epoch: 1, database: dst, isCurrent: () => true);
    final repo = DriftUserSettingsRepository(dst);
    await repo.reserveConsentVersion(capability,
        verifiedFrontier: 2, operationId: 'op');
    final committed = await repo.saveReservedConsentChoice(
        capability, const ConsentChoices(cloud: ConsentState.accepted),
        version: 3, operationId: 'op');
    expect(committed.cloudConsentVersion, 3);

    await RestoreBackupUseCase(dst).call(await BackupSnapshotBuilder(src).build());

    final restored = await repo.getSettings();
    expect(restored.cloudConsentState, ConsentState.unset);
    expect(restored.consentVersion, 0);
    final mark = await dst
        .customSelect('SELECT watermark FROM consent_version_watermark')
        .getSingle();
    expect(mark.read<int>('watermark'), 3, reason: 'the device watermark survived');

    final declined = await repo.saveConsentChoice(
        capability, const ConsentChoices(cloud: ConsentState.declined));
    expect(declined.cloudConsentVersion, greaterThanOrEqualTo(4));
    final next = await repo.reserveConsentVersion(capability,
        verifiedFrontier: 0, operationId: 'op2');
    expect(next, greaterThan(declined.cloudConsentVersion));
  });
}
