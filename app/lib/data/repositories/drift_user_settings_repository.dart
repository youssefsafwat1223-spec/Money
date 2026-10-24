import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../core/session/admission_authority.dart';
import '../../core/session/consent_capability.dart';
import '../../core/session/merchant_preference_writer.dart';
import '../../domain/entities/supporting_entities.dart';
import '../../domain/repositories/user_settings_repository.dart';
import '../../features/planning_sync/services/planning_outbox_queue.dart';
import '../db/app_database.dart';
import '../db/sql_value_codec.dart';
import 'drift_repository_support.dart';

/// MALI-059n: the versioned tri-state consent → nullable TEXT column
/// (unset ⇒ NULL). Read back by `_consentStateFromRow` in the support layer.
Variable _consentStateVariable(ConsentState state) {
  switch (state) {
    case ConsentState.accepted:
      return Variable.withString('accepted');
    case ConsentState.declined:
      return Variable.withString('declined');
    case ConsentState.unset:
      return const Variable<String>(null);
  }
}

class DriftUserSettingsRepository
    implements
        UserSettingsRepository,
        ConsentSettingsWriter,
        MerchantPreferenceWriter {
  DriftUserSettingsRepository(
    this._db, {
    PlanningOutboxQueue? outboxQueue,
    @visibleForTesting void Function()? afterConsentFinalGuard,
    @visibleForTesting Future<void> Function()? beforeMerchantUpdate,
    @visibleForTesting Future<void> Function()? afterMerchantUpdate,
  })  : _outboxQueue = outboxQueue,
        _afterConsentFinalGuard = afterConsentFinalGuard,
        _beforeMerchantUpdate = beforeMerchantUpdate,
        _afterMerchantUpdate = afterMerchantUpdate;

  final AppDatabase _db;
  final Future<void> Function()? _beforeMerchantUpdate;
  final Future<void> Function()? _afterMerchantUpdate;

  /// Test-only, null in production: called synchronously right after the final
  /// authorization check of [saveConsentChoice], before the callback returns, so a
  /// test can start a logout exactly between that check and COMMIT.
  final void Function()? _afterConsentFinalGuard;

  /// A retained service may reject work before touching a retired database.
  bool get isDatabaseOpen => _db.lifecycleState == DatabaseLifecycleState.open;
  final PlanningOutboxQueue? _outboxQueue;

  @override
  Future<UserSettingsEntity> getSettings() async {
    final row = await _db
        .customSelect(
          'SELECT * FROM user_settings LIMIT 1;',
        )
        .getSingle();
    return userSettingsFromRow(row);
  }

  @override
  Future<UserSettingsEntity> saveSettings(UserSettingsEntity settings) =>
      _db.transaction(() => _saveWithinTransaction(settings));

  /// A field-scoped local preference write. No settings snapshot or outbox is
  /// involved, so a concurrent consent decision cannot be carried back here.
  @override
  Future<void> saveMerchantPersonalization(
    AdmissionAuthority authority,
    AppDatabase? database,
    bool enabled,
  ) async {
    void check() {
      authority.requireCurrent();
      if (database == null || !identical(database, _db) || !isDatabaseOpen) {
        throw const StaleAdmissionException();
      }
    }

    check();
    await _db.transaction(() async {
      check();
      final owner = await _db
          .customSelect('SELECT owner_uid FROM replica_meta WHERE id = 1;')
          .getSingleOrNull();
      check();
      if (owner == null || owner.read<String>('owner_uid') != authority.uid) {
        throw const StaleAdmissionException();
      }
      final settingsIds =
          await _db.customSelect('SELECT id FROM user_settings LIMIT 2;').get();
      check();
      if (settingsIds.length != 1) {
        throw StateError('merchant_settings_not_singleton');
      }
      final settingsId = settingsIds.single.read<String>('id');
      await _beforeMerchantUpdate?.call();
      check();
      final affected = await _db.customUpdate(
        'UPDATE user_settings SET merchant_personalization_enabled = ? '
        'WHERE id = ?;',
        variables: [
          Variable.withInt(enabled ? 1 : 0),
          Variable.withString(settingsId),
        ],
      );
      check();
      if (affected != 1) {
        throw StateError('merchant_settings_not_updated');
      }
      await _afterMerchantUpdate?.call();
      // Final synchronous guard before the transaction callback returns.
      check();
    });
  }

  /// The consent decision, as ONE typed transaction. Unlike [saveSettings] it
  /// takes no caller-supplied entity: it reads the CURRENT row and merges only
  /// the consent [choices] into it, so a stale entity can neither carry along nor
  /// overwrite any other setting. The capability, the database and the replica
  /// owner are checked INSIDE the transaction, and again after every awaited
  /// step: after the UPDATE, after the atomic local outbox enqueue and, last, in a
  /// final synchronous check immediately before the callback returns. A failed
  /// check throws [StaleAdmissionException] inside the transaction, so the
  /// settings AND the outbox row roll back together. Drift awaits this callback
  /// and only then sends COMMIT: a choice authorized at that final check is a
  /// legitimate local persistence and is never claimed to be rolled back. The
  /// future completes only after the transaction settled.
  @override
  Future<UserSettingsEntity> saveConsentChoice(
    ConsentCapability capability,
    ConsentChoices choices,
  ) async {
    capability.requireCurrent();
    if (!identical(capability.database, _db)) {
      throw const StaleAdmissionException();
    }
    return _db.transaction(() async {
      capability.requireCurrent();
      final owner = await _db
          .customSelect('SELECT owner_uid FROM replica_meta WHERE id = 1;')
          .getSingleOrNull();
      capability.requireCurrent();
      if (owner == null || owner.read<String>('owner_uid') != capability.uid) {
        throw const StaleAdmissionException();
      }
      final previous = await getSettings();
      capability.requireCurrent();
      final saved = await _saveWithinTransaction(
        choices.applyTo(previous),
        checkpoint: capability.requireCurrent,
      );
      // The FINAL synchronous authorization point: nothing is awaited between
      // this check and the callback returning (COMMIT is sent after that).
      capability.requireCurrent();
      _afterConsentFinalGuard?.call();
      return saved;
    });
  }

  Future<UserSettingsEntity> _saveWithinTransaction(
    UserSettingsEntity settings, {
    void Function()? checkpoint,
  }) async {
    {
      // Cloud/AI consent persists exactly as the user chose (MALI-001) — the
      // former forced-true clamp made the privacy toggles meaningless.
      final requiredSettings = settings;
      final previousSettings = await getSettings();
      // The read above is an async boundary: the lifecycle is revalidated here,
      // BEFORE the first mutation (a failure throws inside the transaction).
      checkpoint?.call();
      final cloudChanged = previousSettings.cloudConsentState !=
          requiredSettings.cloudConsentState;
      final aiChanged =
          previousSettings.aiConsentState != requiredSettings.aiConsentState;
      final consentChanged = cloudChanged || aiChanged;
      // WP-6: versions are assigned HERE from the stored row, never taken from
      // the caller's entity, so a stale entity can neither lower a version nor
      // invent one. Any change of either consent moves the shared version
      // strictly forward; an untouched consent keeps its own version and time.
      final nextVersion = previousSettings.consentVersion + 1;
      final changedAt = dateTimeToSql(DateTime.now().toUtc());
      Variable<String> consentAt(bool changed, DateTime? previous) => changed
          ? Variable.withString(changedAt)
          : previous == null
              ? const Variable<String>(null)
              : Variable.withString(dateTimeToSql(previous.toUtc()));
      await _db.customUpdate(
        '''
        UPDATE user_settings
        SET display_name = ?, phone_number = ?, avatar_path = ?,
            date_of_birth = ?,
            country = ?, currency = ?, language = ?, theme = ?, input_method = ?,
            notifications_json = ?, db_encryption_key_ref = ?,
            privacy_mode_enabled = ?, ai_consent_granted = ?,
            cloud_processing_enabled = ?, ai_consent_state = ?,
            cloud_consent_state = ?,
            cloud_consent_version = ?, cloud_consent_at = ?,
            ai_consent_version = ?, ai_consent_at = ?,
            merchant_personalization_enabled = ?,
            updated_at = ${sqlString(dateTimeToSql(DateTime.now().toUtc()))}
        WHERE id = ?;
      ''',
        variables: [
          requiredSettings.displayName == null
              ? const Variable<String>(null)
              : Variable.withString(requiredSettings.displayName!),
          requiredSettings.phoneNumber == null
              ? const Variable<String>(null)
              : Variable.withString(requiredSettings.phoneNumber!),
          requiredSettings.avatarPath == null
              ? const Variable<String>(null)
              : Variable.withString(requiredSettings.avatarPath!),
          requiredSettings.dateOfBirth == null
              ? const Variable<String>(null)
              : Variable.withString(
                  requiredSettings.dateOfBirth!.toUtc().toIso8601String()),
          Variable.withString(requiredSettings.country),
          Variable.withString(requiredSettings.currency),
          Variable.withString(requiredSettings.language),
          Variable.withString(requiredSettings.theme),
          Variable.withString(requiredSettings.inputMethod),
          Variable.withString(requiredSettings.notificationsJson),
          // MALI-058n — never persist key material: this deprecated column is
          // always written empty, regardless of the entity value.
          const Variable<String>(''),
          Variable.withInt(requiredSettings.privacyModeEnabled ? 1 : 0),
          // MALI-059n: the effective grant is DERIVED from the versioned state,
          // so the boolean and the state can never drift apart on disk.
          Variable.withInt(requiredSettings.aiConsentGranted ? 1 : 0),
          Variable.withInt(requiredSettings.cloudProcessingEnabled ? 1 : 0),
          _consentStateVariable(requiredSettings.aiConsentState),
          _consentStateVariable(requiredSettings.cloudConsentState),
          Variable.withInt(cloudChanged
              ? nextVersion
              : previousSettings.cloudConsentVersion),
          consentAt(cloudChanged, previousSettings.cloudConsentAt),
          Variable.withInt(
              aiChanged ? nextVersion : previousSettings.aiConsentVersion),
          consentAt(aiChanged, previousSettings.aiConsentAt),
          // COUPONS Phase 1 — persisted locally and DELIBERATELY absent from
          // the settings sync payload below. See UserSettingsEntity.
          Variable.withInt(
              requiredSettings.merchantPersonalizationEnabled ? 1 : 0),
          Variable.withString(requiredSettings.id),
        ],
      );
      checkpoint?.call(); // after the SQL, before the outbox
      final changedAtValue = dateTimeFromSql(changedAt);
      final saved = requiredSettings.copyWith(
        cloudConsentVersion:
            cloudChanged ? nextVersion : previousSettings.cloudConsentVersion,
        cloudConsentAt:
            cloudChanged ? changedAtValue : previousSettings.cloudConsentAt,
        aiConsentVersion:
            aiChanged ? nextVersion : previousSettings.aiConsentVersion,
        aiConsentAt: aiChanged ? changedAtValue : previousSettings.aiConsentAt,
      );
      // S2: أدرج التفضيلات السحابية للمزامنة في الخلفية (الأعمدة السحابية فقط).
      await _outboxQueue?.enqueueSettings(
        PlanningSyncOperation.update,
        saved,
        consentChanged: consentChanged,
        previous: previousSettings,
      );
      checkpoint?.call(); // after the atomic local outbox enqueue
      return saved;
    }
  }
}
