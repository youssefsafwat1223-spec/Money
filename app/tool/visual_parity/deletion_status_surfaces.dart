// Guarded presentation-only QA. Never imported by production lib/.
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/auth/immediate_deletion_flow.dart';
import 'package:money_companion/core/backend/supabase_config.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/features/settings/delete_account_screen.dart';

const visualParityDeletionStatusKeys = [
  'deletionPresentationRunning', 'deletionPresentationPending',
  'deletionPresentationUnconfirmed', 'deletionPresentationUnconfirmedStale',
  'deletionPresentationRetryable', 'deletionPresentationFinalFailure',
  'deletionPresentationAdminBlocked', 'deletionPresentationRateLimited',
  'deletionPresentationRejected', 'deletionPresentationCleanupPending',
  'deletionPresentationCompleted',
];
final _events = <String, int>{};
Map<String, int> visualParityDeletionStatusEvents() => Map.unmodifiable(_events);
void _record(String key) => _events.update(key, (n) => n + 1, ifAbsent: () => 1);

class _StatusFlow implements ImmediateDeletionFlow {
  _StatusFlow(this.key);
  final String key;
  @override
  Future<DeletionFlowSession?> begin() =>
      throw StateError('presentation_does_not_authorize_deletion');
  @override
  Future<DeletionFlowSession?> resume() async {
    _record('${key}ResumePresentation');
    return _StatusSession(key);
  }
  @override
  Future<DeletionFlowSession?> resumeLocalCleanup() =>
      throw StateError('presentation_does_not_authorize_cleanup');
}

class _StatusSession implements DeletionFlowSession {
  _StatusSession(this.key);
  final String key;
  @override
  Future<DeletionFlowResult> confirm() =>
      throw StateError('presentation_does_not_authorize_deletion');
  @override
  Future<DeletionFlowResult> retryLocalCleanup() =>
      throw StateError('presentation_does_not_authorize_cleanup');
  @override
  Future<DeletionFlowResult> checkStatus() {
    _record('${key}StatusPresentation');
    // These are view-controller inputs only. No operation, receipt, Apple
    // challenge, gateway, account session or removal service exists here.
    return switch (key) {
      'deletionPresentationRunning' => Completer<DeletionFlowResult>().future,
      'deletionPresentationPending' => Future.value(const DeletionFlowPending()),
      'deletionPresentationUnconfirmed' => Future.value(
          const DeletionFlowUnconfirmed(canCheckStatus: true)),
      'deletionPresentationUnconfirmedStale' => Future.value(
          const DeletionFlowUnconfirmed(canCheckStatus: false)),
      'deletionPresentationRetryable' => Future.value(
          const DeletionFlowFailed(retryable: true)),
      'deletionPresentationFinalFailure' => Future.value(
          const DeletionFlowFailed(retryable: false)),
      'deletionPresentationAdminBlocked' => Future.value(const DeletionFlowAdminBlocked()),
      'deletionPresentationRateLimited' => Future.value(const DeletionFlowRateLimited()),
      'deletionPresentationRejected' => Future.value(const DeletionFlowRejected()),
      'deletionPresentationCleanupPending' => Future.value(const DeletionFlowLocalCleanupPending()),
      'deletionPresentationCompleted' => Future.value(const DeletionFlowCompleted()),
      _ => throw StateError('unsupported_deletion_presentation'),
    };
  }
  @override
  void close() => _record('${key}PresentationClosed');
}

Future<bool> openVisualParityDeletionStatus(
    BuildContext context, WidgetRef ref, String key) async {
  if (!visualParityDeletionStatusKeys.contains(key)) return false;
  if (!kDebugMode || SupabaseConfig.isConfigured) {
    throw StateError('deletion_presentation_requires_offline_debug');
  }
  final db = ref.read(appDatabaseProvider);
  final databases = await db.customSelect('PRAGMA database_list').get();
  if (!databases.any((r) => r.read<String>('name') == 'main' &&
      r.read<String>('file').isEmpty)) {
    throw StateError('deletion_presentation_requires_memory_database');
  }
  if (!context.mounted) return false;
  unawaited(Navigator.of(context).push<void>(MaterialPageRoute<void>(
    builder: (_) => ProviderScope(overrides: [
      immediateDeletionFlowProvider.overrideWithValue(_StatusFlow(key)),
      deleteAccountAfterCompletionProvider.overrideWithValue(
          () => _record('${key}CompletionPresentationCallback')),
    ], child: const DeleteAccountScreen()),
  )));
  return true;
}
