import 'package:drift/drift.dart';

import '../../../data/db/app_database.dart';
import 'capture_import_ports.dart';
import 'capture_receipts.dart';

/// A quarantined item migrated from the v2 queue, as the native layer shows it.
class LegacyCaptureItem {
  const LegacyCaptureItem({
    required this.id,
    required this.text,
    required this.receivedAt,
  });

  final String id;
  final String text;
  final DateTime? receivedAt;
}

/// §4.7 — after the legacy database is ADOPTED into this uid's replica, the
/// replica's own evidence decides what happens to the items the v2 queue left
/// behind (migrated as `unbound`, no hint, never imported automatically):
///
/// - receipt `capture_payload:<id>` or a transaction with `id == capture_id`:
///   already consumed, the item is removed;
/// - same raw text and receive time as an existing transaction (a random-id import whose
///   receipt was lost): annotated `suspected_already_imported`, for review only,
///   NEVER imported (A6);
/// - everything else stays quarantined, unbound and hint-less, and expires.
///
/// Only the active, non-quarantined replica is read; a quarantined legacy
/// database is never inspected.
class LegacyCaptureResolver {
  LegacyCaptureResolver({
    required CaptureImportQueue queue,
    required AppDatabase db,
    required String? Function() sessionUid,
    required Future<String?> Function() replicaOwnerUid,
    this.legacyItems,
  })  : _queue = queue,
        _db = db,
        _receipts = CaptureReceipts(db),
        _sessionUid = sessionUid,
        _replicaOwnerUid = replicaOwnerUid;

  final CaptureImportQueue _queue;
  final AppDatabase _db;
  final CaptureReceipts _receipts;
  final String? Function() _sessionUid;
  final Future<String?> Function() _replicaOwnerUid;

  /// The migrated items, when the native layer can list them (needed only for
  /// the fingerprint review annotation). Null: only receipt-proven removal runs.
  final Future<List<LegacyCaptureItem>> Function()? legacyItems;

  static const Duration _sameTime = Duration(minutes: 1);

  /// Returns how many queue items were removed.
  Future<int> resolve() async {
    final session = _sessionUid();
    if (session == null || await _replicaOwnerUid() != session) return 0;
    final consumed = await _receipts.consumedCandidateIds();
    final suspected = await _suspectedIds(consumed.toSet());
    if (consumed.isEmpty && suspected.isEmpty) return 0;
    return _queue.resolveLegacy(
      consumedIds: consumed,
      suspectedIds: suspected,
    );
  }

  Future<List<String>> _suspectedIds(Set<String> consumed) async {
    final source = legacyItems;
    if (source == null) return const [];
    final suspected = <String>[];
    for (final item in await source()) {
      if (consumed.contains(item.id) || item.receivedAt == null) continue;
      final rows = await _db.customSelect(
        'SELECT sms_received_at AS r, comparison_timestamp AS c '
        'FROM transactions WHERE raw_message = ?;',
        variables: [Variable.withString(item.text)],
      ).get();
      final at = item.receivedAt!.toUtc();
      bool near(String? iso) {
        final t = DateTime.tryParse(iso ?? '')?.toUtc();
        return t != null && t.difference(at).abs() <= _sameTime;
      }

      final matches = rows
          .any((r) => near(r.read<String?>('r')) || near(r.read<String?>('c')));
      if (matches) suspected.add(item.id);
    }
    return suspected;
  }
}
