import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/l10n_ext.dart';
import '../../l10n/app_localizations.dart';
import '../../core/di/app_providers.dart';
import '../../core/sync/conflict_resolver.dart';
import '../../core/sync/conflict_fields.dart';
import '../../core/sync/conflict_policy.dart';
import '../../core/sync/sync_conflict_store.dart';

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
      var resolved = true;
      if (keepLocal) {
        await resolver.resolveKeepLocal(
            widget.conflict.entityType, widget.conflict.localId);
      } else {
        // false = the server row could not be fetched/applied; the conflict
        // stays listed so the user can retry.
        resolved = await resolver.resolveKeepRemote(
            widget.conflict.entityType, widget.conflict.localId);
      }
      ref.invalidate(conflictsProvider);
      if (mounted && resolved) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(keepLocal
                ? context.l10n.pcsKeptMine
                : context.l10n.conflictKeptCloud),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final conflict = widget.conflict;
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final tombstone = conflict.kind == SyncConflictKind.tombstone;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_conflictLabel(context, conflict), style: theme.textTheme.bodyLarge),
        if (tombstone)
          Text(l10n.conflictDeletedInCloud, style: theme.textTheme.bodySmall)
        else if (conflict.kind == SyncConflictKind.delete)
          Text(l10n.conflictDeletedHere, style: theme.textTheme.bodySmall),
        // SYNC-Q5: the meaningful field differences, mine vs cloud.
        for (final d in conflict.fields)
          Padding(
            key: ValueKey('conflict-field-${d.key.name}'),
            padding: const EdgeInsets.only(top: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_fieldLabel(l10n, d.key), style: theme.textTheme.labelMedium),
                Text('${l10n.conflictThisDevice}: ${_shown(l10n, d, d.mine)}',
                    style: theme.textTheme.bodySmall),
                Text('${l10n.conflictCloud}: ${_shown(l10n, d, d.cloud)}',
                    style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            if (conflict.canKeepMine) ...[
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy ? null : () => _resolve(true),
                  child: Text(tombstone
                      ? l10n.conflictKeepMineAsNew
                      : l10n.conflictKeepMine),
                ),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: OutlinedButton(
                onPressed: _busy ? null : () => _resolve(false),
                child: Text(l10n.conflictKeepCloud),
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

String _shown(AppL10n l10n, ConflictFieldDiff d, String? value) {
  if (value == null) return l10n.conflictNotSet;
  // A yes/no field shows a tick or a dash, not a word that needs copy.
  if (d.key == ConflictFieldKey.active) return value == '1' ? '\u2713' : '\u2014';
  return value;
}

String _fieldLabel(AppL10n l10n, ConflictFieldKey key) => switch (key) {
      ConflictFieldKey.amount => l10n.conflictFieldAmount,
      ConflictFieldKey.currency => l10n.conflictFieldCurrency,
      ConflictFieldKey.merchant => l10n.conflictFieldMerchant,
      ConflictFieldKey.note => l10n.conflictFieldNote,
      ConflictFieldKey.date => l10n.conflictFieldDate,
      ConflictFieldKey.status => l10n.conflictFieldStatus,
      ConflictFieldKey.category => l10n.conflictFieldCategory,
      ConflictFieldKey.name => l10n.conflictFieldName,
      ConflictFieldKey.type => l10n.conflictFieldType,
      ConflictFieldKey.balance => l10n.conflictFieldBalance,
      ConflictFieldKey.initialBalance => l10n.conflictFieldInitialBalance,
      ConflictFieldKey.creditLimit => l10n.conflictFieldCreditLimit,
      ConflictFieldKey.period => l10n.conflictFieldPeriod,
      ConflictFieldKey.startDate => l10n.conflictFieldStartDate,
      ConflictFieldKey.endDate => l10n.conflictFieldEndDate,
      ConflictFieldKey.frequency => l10n.conflictFieldFrequency,
      ConflictFieldKey.nextDue => l10n.conflictFieldNextDue,
      ConflictFieldKey.targetAmount => l10n.conflictFieldTargetAmount,
      ConflictFieldKey.deadline => l10n.conflictFieldDeadline,
      ConflictFieldKey.nickname => l10n.conflictFieldNickname,
      ConflictFieldKey.last4 => l10n.conflictFieldLast4,
      ConflictFieldKey.active => l10n.conflictFieldActive,
    };
