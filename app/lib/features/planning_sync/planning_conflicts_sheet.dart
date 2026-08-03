import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/sync/conflict_resolver.dart';

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
        error: (_, __) => const Padding(
          padding: EdgeInsets.all(24),
          child: Text('تعذّر تحميل التعارضات — حاول مجددًا.'),
        ),
        data: (conflicts) {
          if (conflicts.isEmpty) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('لا توجد تعارضات', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                const Text('كل بيانات التخطيط متزامنة.'),
              ],
            );
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('حل تعارضات المزامنة',
                  style: theme.textTheme.titleLarge,
                  textAlign: TextAlign.center),
              const SizedBox(height: 4),
              Text(
                'عُدِّل هذا العنصر على جهاز آخر أيضًا. اختر النسخة التي تريد '
                'الاحتفاظ بها.',
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
                ? 'تم الاحتفاظ بنسختك.'
                : 'تم اعتماد نسخة الجهاز الآخر.'),
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
        Text(widget.conflict.label,
            style: Theme.of(context).textTheme.bodyLarge),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _busy ? null : () => _resolve(true),
                child: const Text('احتفظ بنسختي'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton(
                onPressed: _busy ? null : () => _resolve(false),
                child: const Text('نسخة الجهاز الآخر'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
