import 'package:money_companion/core/session/local_read_authority.dart';
import 'package:money_companion/data/db/replica_store.dart';

/// R8 — the explicit, test-only way to restore a read-only replica without the
/// coordinator reservation and exclusion evidence. The verified replica carries
/// no reservation, so `AccountScopeHost.restoreLocalRead` refuses to publish it.
extension UncoordinatedLocalReadRestore on LocalReadAuthority {
  Future<LocalReadRestore> restoreUncoordinated(ReplicaStore store) =>
      restoreUncoordinatedForTesting(
        store,
        open: (uid, replicaId) =>
            store.openReadOnlyReplicaUncoordinatedForTesting(uid,
                replicaId: replicaId),
      );
}
