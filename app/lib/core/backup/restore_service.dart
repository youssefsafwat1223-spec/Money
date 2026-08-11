import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../data/db/app_database.dart';
import '../../data/db/database_lease.dart';
import '../../data/db/ownership_guard.dart';
import '../../data/db/planning_cutover.dart';
import 'backup_service.dart';
import 'planning_restore_preflight.dart';
import 'restore_backup_usecase.dart';
import 'restore_journal.dart';
import 'restore_plan.dart';
import 'restore_result.dart';

// MALI-014 / MALI-076n (Phase 6 Batch 5 + closure) §2B/§9/§10/§14 — the restore
// MUTATION orchestrator. Consumes ONLY an immutable [RestorePlan], revalidates
// admission, runs the destructive write through the accepted file-exclusive
// maintenance primitive inside one transaction, and records progress in the DURABLE
// restore-operation journal so a crash / acknowledgement loss cannot replay a
// destructive restore. Every failure maps to a typed [RestoreResult].
class RestoreService {
  RestoreService(this._db) : _journal = RestoreJournal(_db);

  final AppDatabase _db;
  final RestoreJournal _journal;

  /// Execute the mutation phase for [plan].
  Future<RestoreResult> execute({
    required RestorePlan plan,
    DatabaseLeaseManager? leaseManager,
    OwnershipGuard? ownershipGuard,
    AdmissionToken? admissionToken,
    Future<void> Function()? afterRestore,
    Duration drainTimeout = const Duration(seconds: 10),
    Duration exclusiveTimeout = const Duration(seconds: 10),
    // MALI-026 (B8-2.10 §5/§7): the live cutover authority (defaults to legacy,
    // so v29 restore is unchanged) and an optional RESTORE_PAYLOAD-scoped repair
    // decision for the continuation retry.
    PlanningCutoverCoordinator planningCoordinator =
        const SchemaV29PlanningCutoverCoordinator(),
    RestorePayloadRepairDecision? planningRepairDecision,
    void Function(String point)? onFaultPoint,
  }) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final genHash = _ownerGenerationHash(admissionToken);

    // §Blocker-1 — DURABLE replay guard (survives a crash/restart, unlike the old
    // in-memory guard). A committed operation is never destructively replayed.
    final existing = await _journal.find(plan.operationId);
    if (existing != null &&
        existing.sourceFingerprint != plan.sourceFingerprint) {
      return RestoreResult(RestoreOutcome.validationFailed,
          operationId: plan.operationId);
    }
    if (existing != null && existing.isCommitted) {
      return RestoreResult(
        existing.state == RestoreJournalState.acknowledged
            ? RestoreOutcome.success
            : RestoreOutcome.committedPendingAcknowledgement,
        operationId: plan.operationId,
        warnings: plan.warnings,
      );
    }

    // §10 — revalidate admission before acquiring the gate.
    if (ownershipGuard != null &&
        admissionToken != null &&
        !await ownershipGuard.isCurrent(admissionToken)) {
      await _journal.markFailedBeforeMutation(
          plan.operationId, 'ownershipChanged', now);
      return RestoreResult(RestoreOutcome.ownershipChanged,
          operationId: plan.operationId);
    }

    await _journal.markPrepared(
      operationId: plan.operationId,
      sourceFingerprint: plan.sourceFingerprint,
      envelopeVersion: plan.envelopeVersion,
      snapshotSchemaVersion: plan.snapshotSchemaVersion,
      ownerGenerationHash: genHash,
      nowIso: now,
    );

    Future<void> mutate() async {
      // §10 — revalidate admission immediately before the transaction.
      if (ownershipGuard != null &&
          admissionToken != null &&
          !await ownershipGuard.isCurrent(admissionToken)) {
        throw const StaleOwnershipException();
      }
      await RestoreBackupUseCase(_db, coordinator: planningCoordinator).call(
        <String, dynamic>{
          'schemaVersion': plan.snapshotSchemaVersion,
          'tables': plan.tables,
        },
        plan: plan,
        journal: _journal,
        operationId: plan.operationId,
        nowIso: now,
        planningRepairDecision: planningRepairDecision,
        onFaultPoint: onFaultPoint,
      );
    }

    try {
      if (leaseManager != null) {
        await _db.runFileExclusiveMaintenance<void>(
          mutate,
          leaseManager: leaseManager,
          ownershipGuard: ownershipGuard,
          admissionToken: admissionToken,
          drainTimeout: drainTimeout,
          exclusiveTimeout: exclusiveTimeout,
        );
      } else {
        await _db.runExclusiveMaintenance<void>(mutate,
            drainTimeout: drainTimeout);
      }
    } on StaleOwnershipException {
      await _journal.markRolledBack(plan.operationId, 'ownershipChanged', now);
      return RestoreResult(RestoreOutcome.ownershipChanged,
          operationId: plan.operationId);
    } on DatabaseLeaseUnavailable {
      await _journal.markRolledBack(plan.operationId, 'maintenanceTimeout', now);
      return RestoreResult(RestoreOutcome.maintenanceTimeout,
          operationId: plan.operationId);
    } on DatabaseBusyException {
      await _journal.markRolledBack(plan.operationId, 'databaseBusy', now);
      return RestoreResult(RestoreOutcome.databaseBusy,
          operationId: plan.operationId);
    } on DatabaseLifecycleException catch (e) {
      if (e.reason == DatabaseLifecycleFailure.recoveryRequired) {
        await _journal.markRecoveryRequired(plan.operationId, now);
        return RestoreResult(RestoreOutcome.recoveryRequired,
            operationId: plan.operationId);
      }
      await _journal.markRolledBack(
          plan.operationId,
          e.reason == DatabaseLifecycleFailure.maintenanceTimeout
              ? 'maintenanceTimeout'
              : 'internal',
          now);
      return RestoreResult(
        e.reason == DatabaseLifecycleFailure.maintenanceTimeout
            ? RestoreOutcome.maintenanceTimeout
            : RestoreOutcome.internalFailure,
        operationId: plan.operationId,
      );
    } on RestorePlanningRepairRequiredException {
      // Thrown BEFORE any destructive mutation — the DB is untouched. The caller
      // repairs the RESTORE_PAYLOAD scope and retries with a decision.
      await _journal.markRolledBack(
          plan.operationId, 'planningRepairRequired', now);
      return RestoreResult(RestoreOutcome.planningCurrencyRepairRequired,
          operationId: plan.operationId);
    } on RestoreVerificationException {
      await _journal.markRolledBack(plan.operationId, 'validationFailed', now);
      return RestoreResult(RestoreOutcome.rollbackCompleted,
          operationId: plan.operationId);
    } on BackupException {
      await _journal.markRolledBack(plan.operationId, 'validationFailed', now);
      return RestoreResult(RestoreOutcome.rollbackCompleted,
          operationId: plan.operationId);
    } catch (_) {
      await _journal.markRolledBack(plan.operationId, 'internal', now);
      return RestoreResult(RestoreOutcome.internalFailure,
          operationId: plan.operationId);
    }

    // Committed durably (the committed marker was written INSIDE the transaction).
    await _journal.prune();
    try {
      if (afterRestore != null) await afterRestore();
    } catch (_) {
      // The destructive commit already stands; the post-restore backfill is
      // best-effort and never un-commits a successful restore.
    }
    return RestoreResult(RestoreOutcome.success,
        operationId: plan.operationId, warnings: plan.warnings);
  }

  /// Idempotently acknowledge a committed restore (the UI calls this after showing
  /// success). Safe to call after a restart that discovered a committed operation.
  Future<void> acknowledge(String operationId) async {
    await _journal.markAcknowledged(
        operationId, DateTime.now().toUtc().toIso8601String());
  }

  /// An opaque, privacy-safe hash of the admission identity — never the raw uid or
  /// generation. Null when no admission is bound.
  static String? _ownerGenerationHash(AdmissionToken? token) {
    if (token == null || token.generation == null) return null;
    return sha256
        .convert(utf8.encode('${token.ownerUid}:${token.generation}'))
        .toString();
  }
}
