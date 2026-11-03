// Failure-only offline review. Never prepares a plan or grants restore authority.
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/backend/supabase_config.dart';
import 'package:money_companion/core/backup/backup_service.dart';
import 'package:money_companion/core/backup/restore_plan.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/features/onboarding/restore_prompt_screen.dart';

const visualParityRestoreNegativeKeys = [
  'restoreWrongPassphrase',
  'restorePreparationFailure'
];
final _events = <String, int>{};
Map<String, int> visualParityRestoreNegativeEvents() =>
    Map.unmodifiable(_events);
void _event(String key) => _events.update(key, (n) => n + 1, ifAbsent: () => 1);
FailureOnlyRestorePreparation? _active;
void releaseVisualParityRestoreNegative() => _active?.release();

class FailureOnlyRestorePreparation implements BackupService {
  FailureOnlyRestorePreparation(this.key);
  final String key;
  final gate = Completer<void>();
  int calls = 0;
  void release() {
    if (!gate.isCompleted) {
      gate.complete();
    }
  }

  @override
  Future<RestorePlan> prepareRestore({required String passphrase}) async {
    if (passphrase != 'qa-restore-secret') {
      throw StateError('unexpected_restore_preview_input');
    }
    calls++;
    _event('${key}Admitted');
    await gate.future;
    throw BackupException('private_synthetic_restore_failure',
        code: key == 'restoreWrongPassphrase'
            ? BackupError.wrongPassphrase
            : BackupError.prepareFailed);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    _event('${key}Forbidden');
    throw StateError('restore_preview_operation_forbidden');
  }
}

Future<bool> openVisualParityRestoreNegative(
    BuildContext context, WidgetRef ref, String key) async {
  if (!visualParityRestoreNegativeKeys.contains(key)) {
    return false;
  }
  if (!kDebugMode || SupabaseConfig.isConfigured) {
    throw StateError('restore_preview_requires_offline_debug');
  }
  final db = ref.read(appDatabaseProvider);
  final databases = await db.customSelect('PRAGMA database_list').get();
  if (!databases.any((r) =>
      r.read<String>('name') == 'main' && r.read<String>('file').isEmpty)) {
    throw StateError('restore_preview_requires_memory');
  }
  if (!context.mounted) {
    return false;
  }
  final service = FailureOnlyRestorePreparation(key);
  _active = service;
  _event('${key}Opened');
  unawaited(Navigator.of(context)
      .push<void>(MaterialPageRoute<void>(
          builder: (_) => ProviderScope(
              overrides: [backupServiceProvider.overrideWithValue(service)],
              child: const RestorePromptScreen(onboardingFlow: false))))
      .whenComplete(() {
    service.release();
    if (identical(_active, service)) {
      _active = null;
    }
    _event('${key}Closed');
  }));
  return true;
}
