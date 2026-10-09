import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../../data/db/replica_store.dart';
import '../../data/sync/seq_pull.dart';
import '../../data/sync/sync_cursor.dart';
import '../../features/capture/services/capture_import_ports.dart';
import '../../features/capture/services/capture_import_service.dart';
import '../session/account_scope.dart';
import '../session/admission_authority.dart';
import '../session/rebootstrap_service.dart';
import '../session/replica_recovery.dart';
import 'app_providers.dart';

/// WP-7 — the process-level pieces the rebootstrap needs that live outside the
/// account scope (the replica store, the scope host, the Remove-data flow).
/// Configured once by the bootstrap runner.
class RebootstrapRuntime {
  RebootstrapRuntime._();
  static final RebootstrapRuntime instance = RebootstrapRuntime._();

  ReplicaStore? store;
  AccountScopeControl? scope;
  Future<void> Function(String uid)? removeData;
  Future<void> Function(String uid, AdmissionAuthority? authority)? readmit;

  /// F2: the authority a rebootstrap of a uid holds (create the staging replica,
  /// re-admit after a purge). An explicit Remove data revokes it for good.
  Future<AdmissionAuthority> Function(String uid)? maintenanceAuthority;
}

/// Tombstones included: the cloud's rows for recovered client request ids.
class SupabaseLedgerLookup implements LedgerServerLookup {
  const SupabaseLedgerLookup(this.uid);
  final String uid;

  @override
  Future<Map<String, Map<String, dynamic>>> byClientRequestId(
      Set<String> ids) async {
    final out = <String, Map<String, dynamic>>{};
    final list = ids.toList();
    for (var i = 0; i < list.length; i += 100) {
      final rows = await supabase.Supabase.instance.client
          .from('user_transactions')
          .select()
          .eq('user_id', uid)
          .inFilter('client_request_id', list.sublist(i, i + 100 > list.length ? list.length : i + 100));
      for (final r in rows as List) {
        final m = Map<String, dynamic>.from(r as Map);
        out[m['client_request_id'] as String] = m;
      }
    }
    return out;
  }
}

/// The CAP-5 quiescence barrier as the rebootstrap's capture control. After the
/// swap the deferred removals and ACKs are replayed here against the NEW replica
/// (only ids whose receipt is in it), then the barrier is dropped.
class ImportServiceCaptureControl implements RebootstrapCaptureControl {
  ImportServiceCaptureControl(this._import, this._queue, this._server);
  final CaptureImportService _import;
  final CaptureImportQueue _queue;
  final CaptureServerPort _server;

  @override
  Future<void> hold() => _import.acquireBarrier();

  @override
  Set<String> get deferredCaptureIds => _import.deferredCaptureIds;

  @override
  Future<void> resume(Set<String> committed) async {
    for (final id in committed) {
      await _queue.acknowledge(id);
    }
    if (committed.isNotEmpty) {
      try {
        await _server.acknowledge(committed.toList());
      } catch (_) {}
    }
  }
}

/// Null until the bootstrap runner configured [RebootstrapRuntime]. Built per
/// scope generation; everything it needs is captured up front because the scope
/// (and so this provider) is disposed while the swap runs.
final rebootstrapTriggerProvider = Provider<EpochRebootstrapTrigger?>((ref) {
  final rt = RebootstrapRuntime.instance;
  final store = rt.store, scope = rt.scope, removeData = rt.removeData;
  if (store == null || scope == null || removeData == null) return null;
  final caps = ref.watch(serverCapabilitiesServiceProvider);
  final importService = ref.watch(captureImportServiceProvider);
  final control = ImportServiceCaptureControl(importService,
      const NativeCaptureImportQueue(), ref.watch(captureServerPortProvider));
  final uid = supabase.Supabase.instance.client.auth.currentUser?.id;
  if (uid == null) return null;
  final service = RebootstrapService(
    store: store,
    capture: control,
    scope: scope,
    lookup: SupabaseLedgerLookup(uid),
    removeData: removeData,
    readmit: rt.readmit,
    maintenanceAuthority: rt.maintenanceAuthority,
    bootstrapFresh: (fresh, uid) async {
      final c = ProviderContainer(
          overrides: [appDatabaseProvider.overrideWithValue(fresh)]);
      try {
        await c.read(planningSyncEngineProvider).syncParents();
        await c.read(ledgerSyncEngineProvider).sync();
        await c.read(smartInboxSyncServiceProvider).pull();
        await c.read(planningSyncEngineProvider).syncChildren();
        // The pull records the server epoch only after reaching the head: no
        // recorded epoch means it did not run (consent, network, capability).
        if (await readRecordedSyncEpoch(fresh, uid) == null) {
          throw StateError('fresh replica did not reach the server head');
        }
      } finally {
        c.dispose();
      }
    },
  );
  return EpochRebootstrapTrigger(
    store: store,
    service: service,
    capability: () => caps.replicaEpoch(),
    remote: const SupabaseSeqRemote(),
    recordedEpoch: (uid) async => readRecordedSyncEpoch(ref.read(appDatabaseProvider), uid),
  );
});
