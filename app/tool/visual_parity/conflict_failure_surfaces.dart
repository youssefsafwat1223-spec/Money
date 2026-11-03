// Offline presentation QA: failure-only resolver, no authority/DB/network work.
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/backend/supabase_config.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/sync/conflict_resolver.dart';
import 'package:money_companion/core/theme/widgets/glass_sheet.dart';
import 'package:money_companion/features/planning_sync/planning_conflicts_sheet.dart';

const visualParityConflictFailureKeys = [
  'conflictFailureLocal',
  'conflictFailureRemote',
  'conflictFailureFalse'
];
final _events = <String, int>{};
Map<String, int> visualParityConflictFailureEvents() =>
    Map.unmodifiable(_events);
void _event(String key) => _events.update(key, (n) => n + 1, ifAbsent: () => 1);
_FailureOnlyResolver? _active;
void releaseVisualParityConflictFailure() => _active?.release();

class _FailureOnlyResolver implements UniversalConflictResolver {
  _FailureOnlyResolver(this.key);
  final String key;
  final _gate = Completer<void>();
  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  Future<bool> _fail(String type, String id) async {
    if (type != 'goal' || id != 'visual-conflict') {
      throw StateError('unexpected_conflict');
    }
    _event('${key}Admitted');
    await _gate.future;
    if (key == 'conflictFailureFalse') return false;
    throw StateError('private_visual_resolution_failure');
  }

  @override
  Future<void> resolveKeepLocal(String type, String id) async {
    await _fail(type, id);
  }

  @override
  Future<bool> resolveKeepRemote(String type, String id) => _fail(type, id);
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('conflict_fixture_forbidden_operation');
}

Future<bool> openVisualParityConflictFailure(
    BuildContext context, WidgetRef ref, String key) async {
  if (!visualParityConflictFailureKeys.contains(key)) return false;
  if (!kDebugMode || SupabaseConfig.isConfigured) {
    throw StateError('conflict_failure_requires_offline_debug');
  }
  final databases = await ref
      .read(appDatabaseProvider)
      .customSelect('PRAGMA database_list')
      .get();
  if (!databases.any((r) =>
      r.read<String>('name') == 'main' && r.read<String>('file').isEmpty)) {
    throw StateError('conflict_failure_requires_memory');
  }
  if (!context.mounted) return false;
  final resolver = _FailureOnlyResolver(key);
  _active = resolver;
  _event('${key}Opened');
  unawaited(showGlassSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => ProviderScope(overrides: [
            conflictsProvider.overrideWith((ref) async => const [
                  SyncConflict(
                      entityType: 'goal',
                      localId: 'visual-conflict',
                      label: 'QA goal')
                ]),
            conflictResolverProvider.overrideWithValue(resolver),
          ], child: const PlanningConflictsSheet())).whenComplete(() {
    resolver.release();
    if (identical(_active, resolver)) _active = null;
    _event('${key}Closed');
  }));
  return true;
}
