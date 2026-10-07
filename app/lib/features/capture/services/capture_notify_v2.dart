import 'package:drift/drift.dart';

import '../../../data/db/app_database.dart';
import '../../../domain/usecases/ingest_captured_message_usecase.dart';
import 'capture_import_service.dart';
import 'capture_notification_authority.dart';

/// CAP-7 (`capture_notify_v2`): the post-import alert decisions of the iOS
/// notification journey (manifest §5 / plan §15). Pure decisions over injected
/// sinks, so the rules are directly testable.
///
/// - One channel owns a capture's FIRST alert. The App Intent owns it on the
///   capturing phone (`push_attempted` false / offline / localOnly) and APNs owns
///   it when the server handed the push off. Both leave the native item `sent`,
///   so the app alerts only for an item the native side did not (no duplicate).
/// - The app never alerts twice for one capture: its state is persisted
///   ([CaptureNotificationState]) and any state past "none" blocks a second one.
/// - More than [summaryThreshold] fresh transactions in one drain become ONE
///   summary alert; the rows stay individually imported (T-D10).
/// - A capture the native side already alerted for, and that the local parser
///   then turned into a transaction, gets a correction ("Transaction added")
///   that replaces the stale alert, only if that alert is still delivered.
///
/// Alert TEXT is never decided here: every sink is generic (Q3 / X9).
class CaptureNotifyV2 {
  CaptureNotifyV2({
    required CaptureNotificationState state,
    required Future<void> Function(CapturedMessageResult local) showIndividual,
    required Future<void> Function(int count) showSummary,
    required Future<bool> Function(String captureId) withdrawNativeAlert,
    required Future<void> Function(String transactionId) showCorrection,
  })  : _state = state,
        _showIndividual = showIndividual,
        _showSummary = showSummary,
        _withdrawNativeAlert = withdrawNativeAlert,
        _showCorrection = showCorrection;

  /// Plan §15: a drain of MORE than this many fresh transactions is summarised.
  static const int summaryThreshold = 3;

  final CaptureNotificationState _state;
  final Future<void> Function(CapturedMessageResult local) _showIndividual;
  final Future<void> Function(int count) _showSummary;
  final Future<bool> Function(String captureId) _withdrawNativeAlert;
  final Future<void> Function(String transactionId) _showCorrection;

  static bool _isTransaction(CapturedMessageResult? local) =>
      local != null &&
      local.transactionId != null &&
      local.disposition != CapturedMessageDisposition.unprocessable &&
      local.disposition != CapturedMessageDisposition.ignored;

  Future<void> alertForImport(List<CaptureImportItem> imported) async {
    final transactions = <CaptureImportItem>[];
    final others = <CaptureImportItem>[];
    for (final item in imported) {
      if (item.path == CaptureImportPath.alreadyImported) continue;
      if (await _state.stateOf(item.id) != null) continue;
      final local = item.local;
      final nativeOwned = item.message?.status ==
          CaptureNotificationAuthority.statusAlreadyNotified;
      if (nativeOwned) {
        if (item.path == CaptureImportPath.local && _isTransaction(local)) {
          await _correct(item, local!.transactionId!);
        }
        continue;
      }
      if (local == null ||
          local.disposition == CapturedMessageDisposition.ignored) {
        continue;
      }
      (_isTransaction(local) ? transactions : others).add(item);
    }
    for (final item in others) {
      await _alert(item, CaptureAlertState.app);
    }
    if (transactions.length > summaryThreshold) {
      await _showSummary(transactions.length);
      for (final item in transactions) {
        await _state.mark(item.id, CaptureAlertState.summary);
      }
    } else {
      for (final item in transactions) {
        await _alert(item, CaptureAlertState.app);
      }
    }
  }

  Future<void> _alert(CaptureImportItem item, String state) async {
    await _showIndividual(item.local!);
    await _state.mark(item.id, state);
  }

  Future<void> _correct(CaptureImportItem item, String transactionId) async {
    if (!await _withdrawNativeAlert(item.id)) return;
    await _showCorrection(transactionId);
    await _state.mark(item.id, CaptureAlertState.corrected);
  }
}

/// The values of a capture's alert state (plan §15, `none` = no row).
class CaptureAlertState {
  const CaptureAlertState._();

  /// The app showed the first alert itself.
  static const String app = 'app';

  /// The app counted it in a backlog summary.
  static const String summary = 'summary';

  /// A stale native alert was replaced by the correction.
  static const String corrected = 'corrected';
}

/// Per-capture alert state, kept on the device in the replica's `dedup_hashes`
/// (excluded from backup, wiped with the replica) under `capture_notified:<id>`;
/// no schema change. Holds only the capture id and a state word, never content.
class CaptureNotificationState {
  CaptureNotificationState(this._db);

  final AppDatabase _db;

  static const String prefix = 'capture_notified:';

  /// The state word, or null for `none`.
  Future<String?> stateOf(String captureId) async {
    final rows = await _db.customSelect(
      'SELECT transaction_id AS s FROM dedup_hashes WHERE hash = ?;',
      variables: [Variable.withString('$prefix$captureId')],
    ).get();
    return rows.isEmpty ? null : rows.single.read<String>('s');
  }

  Future<void> mark(String captureId, String state) async {
    final now = DateTime.now().toUtc().toIso8601String();
    await _db.customInsert(
      'INSERT OR REPLACE INTO dedup_hashes(hash, transaction_id, occurred_at, saved_at) '
      'VALUES (?, ?, ?, ?);',
      variables: [
        Variable.withString('$prefix$captureId'),
        Variable.withString(state),
        Variable.withString(now),
        Variable.withString(now),
      ],
    );
  }
}
