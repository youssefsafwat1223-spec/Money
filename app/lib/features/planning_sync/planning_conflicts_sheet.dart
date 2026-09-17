import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/l10n_ext.dart';
import '../../core/di/app_providers.dart';
import '../../core/sync/conflict_resolver.dart';
import '../../core/sync/conflict_policy.dart';

/// MALI-022 part 2 — the visible conflict-resolution surface. Lists planning
/// rows stuck in `sync_status='conflict'` (a real two-device edit collision)
/// and lets the user keep their version or the other device's. Before this,
/// conflicts were flagged and then left forever with no way out.
class PlanningConflictsSheet extends ConsumerWidget {
  const PlanningConflictsSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const PlanningConflictsSheet(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final conflictsAsync = ref.watch(conflictsProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: conflictsAsync.when(
        loading: () => const Padding(
          padding: EdgeInsets.all(32),
          child: Center(child: CircularProgressIndicator()),
        ),
        error: (_, __) => Padding(
          padding: const EdgeInsets.all(24),
          child: Text(context.l10n.pcsLoadFailed),
        ),
        data: (conflicts) {
          if (conflicts.isEmpty) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(context.l10n.pcsNoConflicts, style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                Text(context.l10n.pcsAllSynced),
              ],
            );
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(context.l10n.pcsTitle,
                  style: theme.textTheme.titleLarge,
                  textAlign: TextAlign.center),
              const SizedBox(height: 4),
              Text(
                context.l10n.pcsIntro,
                style: theme.textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: conflicts.length,
                  separatorBuilder: (_, __) => const Divider(height: 24),
                  itemBuilder: (context, i) => _ConflictRow(
                    key: ValueKey(
                        '${conflicts[i].entityType}-${conflicts[i].localId}'),
                    conflict: conflicts[i],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ConflictRow extends ConsumerStatefulWidget {
  const _ConflictRow({required this.conflict, super.key});
  final SyncConflict conflict;

  @override
  ConsumerState<_ConflictRow> createState() => _ConflictRowState();
}

class _ConflictRowState extends ConsumerState<_ConflictRow> {
  bool _busy = false;

  Future<void> _resolve(bool keepLocal) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final resolver = ref.read(conflictResolverProvider);
      if (keepLocal) {
        await resolver.resolveKeepLocal(
            widget.conflict.entityType, widget.conflict.localId);
      } else {
        await resolver.resolveKeepRemote(
            widget.conflict.entityType, widget.conflict.localId);
      }
      ref.invalidate(conflictsProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(keepLocal
                ? context.l10n.pcsKeptMine
                : context.l10n.pcsKeptTheirs),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_conflictLabel(context, widget.conflict),
            style: Theme.of(context).textTheme.bodyLarge),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _busy ? null : () => _resolve(true),
                child: Text(context.l10n.pcsKeepMine),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton(
                onPressed: _busy ? null : () => _resolve(false),
                child: Text(context.l10n.pcsKeepTheirs),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// A conflicted row's label, in the reader's language.
///
/// `labelSql` returns a data column for every entity that has a name. A budget
/// has none, so its label is composed — and composing it in SQL put an Arabic
/// word on this sheet in every language. The amount comes from the query; the
/// word comes from here.
String _conflictLabel(BuildContext context, SyncConflict conflict) {
  if (conflict.entityType == ConflictEntities.budget) {
    return context.l10n.conflictBudgetLabel(conflict.label);
  }
  return conflict.label;
}
