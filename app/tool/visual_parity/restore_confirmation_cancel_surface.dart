// Synthetic prepared-plan DTO for confirmation layout/Cancel only.
// Never a real download, decrypted backup, authority or accepted restore result.
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/backend/supabase_config.dart';
import 'package:money_companion/core/backup/backup_service.dart';
import 'package:money_companion/core/backup/restore_plan.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/features/onboarding/restore_prompt_screen.dart';

const visualParityRestoreCancelKey = 'restoreConfirmationCancelPresentation';
final _events = <String, int>{};
void _event(String key) => _events.update(key, (n) => n + 1, ifAbsent: () => 1);
Map<String, int> visualParityRestoreCancelEvents() => Map.unmodifiable(_events);

class PresentationOnlyPreparedRestore implements BackupService {
  int calls = 0;
  int forbiddenCalls = 0;
  @override
  Future<RestorePlan> prepareRestore({required String passphrase}) async {
    if (passphrase != 'qa-restore-secret') {
      throw StateError('unexpected_restore_cancel_input');
    }
    calls++;
    _event('restoreCancelPreparedDTO');
    // RestorePlan is an immutable data transfer object, not RestoreConfirmation.
    // Only the real controller's Confirm branch can mint that capability, and
    // this fixture authorizes Cancel only. All commit/verify/ack calls fail.
    return RestorePlan(
        operationId: 'visual-cancel-only',
        envelopeVersion: 3,
        snapshotSchemaVersion: 3,
        sourceFingerprint: 'synthetic-view-input',
        tables: const {},
        warnings: const []);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    forbiddenCalls++;
    _event('restoreCancelForbidden');
    throw StateError('restore_cancel_presentation_forbids_operation');
  }
}

Future<bool> openVisualParityRestoreCancel(
    BuildContext context, WidgetRef ref, String key) async {
  if (key != visualParityRestoreCancelKey) {
    return false;
  }
  if (!kDebugMode || SupabaseConfig.isConfigured) {
    throw StateError('restore_cancel_requires_offline_debug');
  }
  final db = ref.read(appDatabaseProvider);
  final databases = await db.customSelect('PRAGMA database_list').get();
  if (!databases.any((r) =>
      r.read<String>('name') == 'main' && r.read<String>('file').isEmpty)) {
    throw StateError('restore_cancel_requires_memory');
  }
  if (!context.mounted) {
    return false;
  }
  _event('restoreCancelOpened');
  unawaited(Navigator.of(context)
      .push<void>(MaterialPageRoute<void>(
          builder: (_) => ProviderScope(overrides: [
                backupServiceProvider
                    .overrideWithValue(PresentationOnlyPreparedRestore())
              ], child: const RestorePromptScreen(onboardingFlow: false))))
      .whenComplete(() => _event('restoreCancelClosed')));
  return true;
}
