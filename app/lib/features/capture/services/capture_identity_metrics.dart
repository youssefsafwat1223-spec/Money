import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../data/db/app_database.dart';
import '../../../data/sync/sync_cursor.dart';

/// R9: device-local identity-quality counters for native iOS captures.
///
/// An iOS Shortcut that omits Date Received falls back to the current time,
/// which makes the capture id (a hash that includes the receive time)
/// unstable. This counts how many acknowledged captures carried that
/// inference, against all captures that report the marker, so the rate can be
/// watched without reading any message.
///
/// Counts only — never SMS text, sender, amount or payload id. Stored in the
/// existing `sync_cursors` key-value row (wiped on sign-out, no schema change),
/// the same place [SyncHealth] persists its snapshots. Best-effort: a failure
/// here must never affect the capture drain.
class CaptureIdentityMetrics {
  CaptureIdentityMetrics._();

  static const entity = 'capture_identity_metrics';

  /// Records one acknowledged capture. [receivedAtInferred] null means the
  /// native layer did not report the marker (share extension, older build) and
  /// nothing is counted.
  static Future<void> record(AppDatabase db, bool? receivedAtInferred) async {
    if (receivedAtInferred == null) return;
    try {
      final current = await read(db);
      await writeSyncCursor(
        db,
        entity,
        SyncCursor(
          updatedAt: DateTime.now().toUtc().toIso8601String(),
          id: jsonEncode({
            'total': current.total + 1,
            'received_at_inferred':
                current.receivedAtInferred + (receivedAtInferred ? 1 : 0),
          }),
        ),
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[CaptureIdentityMetrics] record failed: ${e.runtimeType}');
      }
    }
  }

  static Future<({int total, int receivedAtInferred})> read(
    AppDatabase db,
  ) async {
    final cursor = await readSyncCursor(db, entity);
    try {
      final json = jsonDecode(cursor.id) as Map;
      return (
        total: (json['total'] as num?)?.toInt() ?? 0,
        receivedAtInferred: (json['received_at_inferred'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return (total: 0, receivedAtInferred: 0);
    }
  }
}
