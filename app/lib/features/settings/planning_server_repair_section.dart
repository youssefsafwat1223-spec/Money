// MALI-026 (Phase-9F-2 §3/§4) — surfaces SERVER-originated unresolved-currency
// planning rows (from the sync quarantine) with an explicit owner currency choice.
// Self-contained: renders nothing when there is no server repair work, so it can be
import '../../core/utils/l10n_ext.dart';
// prepended to the existing (local-legacy) repair screen without touching its flow.
// The currency field starts EMPTY — never preselects base/account/settings.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/finance/currency_scale.dart';
import '../planning_sync/services/planning_server_currency_repair.dart';
import 'planning_server_repair_providers.dart';

class PlanningServerRepairSection extends ConsumerWidget {
  const PlanningServerRepairSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items =
        ref.watch(serverUnresolvedPlanningItemsProvider).valueOrNull ??
            const <PlanningRepairItem>[];
    if (items.isEmpty) return const SizedBox.shrink();
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Card(
        key: const ValueKey('server-unresolved-repair'),
        margin: const EdgeInsets.all(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(context.l10n.psrTitle,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(
                context.l10n.psrIntro,
              ),
              const SizedBox(height: 8),
              for (final item in items) _ServerRepairRow(item: item),
            ],
          ),
        ),
      ),
    );
  }
}

class _ServerRepairRow extends ConsumerStatefulWidget {
  const _ServerRepairRow({required this.item});
  final PlanningRepairItem item;
  @override
  ConsumerState<_ServerRepairRow> createState() => _ServerRepairRowState();
}

class _ServerRepairRowState extends ConsumerState<_ServerRepairRow> {
  // Starts EMPTY: the owner must make an explicit choice (§4 — no default).
  final _controller = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _resolve() async {
    final code = _controller.text.trim().toUpperCase();
    final messenger = ScaffoldMessenger.of(context);
    if (!isSupportedCurrency(code)) {
      messenger.showSnackBar(SnackBar(content: Text(context.l10n.psrUnsupported)));
      return;
    }
    setState(() => _busy = true);
    final outcome =
        await ref.read(planningServerCurrencyRepairServiceProvider).resolve(
              entityType: widget.item.entityType,
              serverId: widget.item.serverId,
              currency: code,
            );
    if (!mounted) return;
    setState(() => _busy = false);
    final ok = outcome == PlanningRepairOutcome.resolved ||
        outcome == PlanningRepairOutcome.resolvedByRemoval;
    messenger.showSnackBar(SnackBar(
        content: Text(ok ? context.l10n.psrConfirmed : context.l10n.psrConfirmFailed)));
    ref.invalidate(serverUnresolvedPlanningItemsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final kind = item.entityType == 'goal' ? context.l10n.rprGoal : context.l10n.rprBudget;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$kind: ${item.title ?? kind}'),
          if (item.amountText != null)
            Text(context.l10n.psrAmount(item.amountText ?? ''),
                style: const TextStyle(color: Colors.grey)),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  textCapitalization: TextCapitalization.characters,
                  decoration: InputDecoration(
                    hintText: context.l10n.psrCurrencyExample,
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _busy ? null : _resolve,
                child: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(context.l10n.txnConfirm),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
