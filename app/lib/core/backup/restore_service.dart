import '../../data/db/app_database.dart';
import '../../data/db/database_lease.dart';
import '../../data/db/ownership_guard.dart';
import 'backup_service.dart';
import 'restore_backup_usecase.dart';
import 'restore_plan.dart';
import 'restore_result.dart';

// MALI-014 / MALI-076n (Phase 6 Batch 5) §2B/§9/§10/§14 — the restore MUTATION
// orchestrator. It consumes ONLY an immutable [RestorePlan], revalidates admission,
// runs the destructive write through the accepted file-exclusive maintenance
// primitive inside one transaction, and maps every failure to a typed
// [RestoreResult] (never a raw error). Operation ids guard against destructive
// replay; ownership changes abort without mutation.
class RestoreService {
  RestoreService(this._db);

  final AppDatabase _db;

  // §9 — in-memory replay state (no schema table). operationId → source fingerprint,
  // plus the set of operations that have committed. A committed operation is never
  // destructively replayed; the same operation id with a different source is
  // rejected. (A process restart cannot cause a double-restore: SQLite guarantees
  // the committed transaction is whole, and a re-run over the already-restored DB is
  // INSERT-OR-REPLACE idempotent.)
  final Map<String, String> _opFingerprints = {};
  final Set<String> _committedOps = {};

  /// Execute the mutation phase for [plan]. [leaseManager] is the accepted process
  /// lease coordinator; [ownershipGuard]/[admissionToken] bind the operation to the
  /// current admission; [afterRestore] is the best-effort post-restore backfill.
  /// [leaseManager] is the accepted cross-isolate process lease coordinator; when
  /// supplied the mutation runs under the FILE-exclusive gate (production, where
  /// background isolates exist). When null (e.g. a single-connection in-memory DB
  /// in tests) it falls back to LOGICAL maintenance — which still drains borrows
  /// and serialises, and there are no cross-isolate secondaries to fence.
  Future<RestoreResult> execute({
    required RestorePlan plan,
    DatabaseLeaseManager? leaseManager,
    OwnershipGuard? ownershipGuard,
    AdmissionToken? admissionToken,
    Future<void> Function()? afterRestore,
    Duration drainTimeout = const Duration(seconds: 10),
    Duration exclusiveTimeout = const Duration(seconds: 10),
  }) async {
    // §9 — replay guard. A reused operation id must carry the same source.
    final priorFingerprint = _opFingerprints[plan.operationId];
    if (priorFingerprint != null &&
        priorFingerprint != plan.sourceFingerprint) {
      return RestoreResult(RestoreOutcome.validationFailed,
          operationId: plan.operationId);
    }
    _opFingerprints[plan.operationId] = plan.sourceFingerprint;
    if (_committedOps.contains(plan.operationId)) {
      // Idempotent acknowledgement — never mutate a second time.
      return RestoreResult(RestoreOutcome.success,
          operationId: plan.operationId, warnings: plan.warnings);
    }

    // §10 — revalidate admission before acquiring the gate.
    if (ownershipGuard != null &&
        admissionToken != null &&
        !await ownershipGuard.isCurrent(admissionToken)) {
      return RestoreResult(RestoreOutcome.ownershipChanged,
          operationId: plan.operationId);
    }

    Future<void> mutate() async {
      // §10 — revalidate admission immediately before the transaction, after
      // borrows drained and the exclusive gate is held.
      if (ownershipGuard != null &&
          admissionToken != null &&
          !await ownershipGuard.isCurrent(admissionToken)) {
        throw const StaleOwnershipException();
      }
      await RestoreBackupUseCase(_db).call(
        <String, dynamic>{
          'schemaVersion': plan.snapshotSchemaVersion,
          'tables': plan.tables,
        },
        plan: plan,
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
      return RestoreResult(RestoreOutcome.ownershipChanged,
          operationId: plan.operationId);
    } on DatabaseLeaseUnavailable {
      return RestoreResult(RestoreOutcome.maintenanceTimeout,
          operationId: plan.operationId);
    } on DatabaseBusyException {
      return RestoreResult(RestoreOutcome.databaseBusy,
          operationId: plan.operationId);
    } on DatabaseLifecycleException catch (e) {
      return RestoreResult(
        switch (e.reason) {
          DatabaseLifecycleFailure.recoveryRequired =>
            RestoreOutcome.recoveryRequired,
          DatabaseLifecycleFailure.maintenanceTimeout =>
            RestoreOutcome.maintenanceTimeout,
          _ => RestoreOutcome.internalFailure,
        },
        operationId: plan.operationId,
      );
    } on RestoreVerificationException {
      // Verification threw INSIDE the transaction → it rolled back, DB intact.
      return RestoreResult(RestoreOutcome.rollbackCompleted,
          operationId: plan.operationId);
    } on BackupException {
      // FK violation / unsupported table thrown inside the transaction → rolled
      // back, the original database is preserved.
      return RestoreResult(RestoreOutcome.rollbackCompleted,
          operationId: plan.operationId);
    } catch (_) {
      return RestoreResult(RestoreOutcome.internalFailure,
          operationId: plan.operationId);
    }

    _committedOps.add(plan.operationId);
    try {
      if (afterRestore != null) await afterRestore();
    } catch (_) {
      // The destructive commit already stands; the post-restore backfill is
      // best-effort and never un-commits a successful restore.
    }
    return RestoreResult(RestoreOutcome.success,
        operationId: plan.operationId, warnings: plan.warnings);
  }
}
