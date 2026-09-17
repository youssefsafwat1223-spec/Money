import 'package:flutter/material.dart';

import '../../core/backup/planning_restore_preflight.dart';
import '../../core/utils/l10n_ext.dart';
import '../../data/db/planning_currency_repair.dart' show PlanningRepairMode;
import '../../domain/finance/currency_scale.dart';
import '../common/app_header.dart';

/// MALI-026 (Phase-8 B8-2.10 §6) — the RESTORE_PAYLOAD-scoped currency repair UX.
///
/// Shown when [inspectRestoreSnapshotPlanning] reports a canonical live DB and a
/// currency-less planning payload. It is bound to the PAYLOAD's own fingerprint
/// (never the live-dataset manifest), and emits a [RestorePayloadRepairDecision]
/// scoped to that fingerprint so the restore can continue (§7). Cancel aborts the
/// restore — the caller leaves the current DB untouched.
///
/// The wording matches §15's truthful framing: the user chooses how to TREAT the
/// backed-up items, not a rediscovered "original" currency.
class RestorePayloadRepairView extends StatefulWidget {
  const RestorePayloadRepairView({
    super.key,
    required this.rows,
    required this.onConfirm,
    required this.onCancel,
  });

  final List<RestorePlanningRow> rows;
  final void Function(RestorePayloadRepairDecision decision) onConfirm;
  final VoidCallback onCancel;

  @override
  State<RestorePayloadRepairView> createState() =>
      _RestorePayloadRepairViewState();
}

class _RestorePayloadRepairViewState extends State<RestorePayloadRepairView> {
  PlanningRepairMode _mode = PlanningRepairMode.global;
  final _globalController = TextEditingController(text: 'SAR');
  final Map<String, String> _perRow = {};
  String? _error;

  @override
  void initState() {
    super.initState();
    for (final r in widget.rows) {
      _perRow[r.id] = 'SAR';
    }
  }

  @override
  void dispose() {
    _globalController.dispose();
    super.dispose();
  }

  String get _fingerprint => restorePayloadFingerprint(widget.rows);

  void _confirm() {
    if (_mode == PlanningRepairMode.global) {
      final code = _globalController.text.trim().toUpperCase();
      if (!isSupportedCurrency(code)) {
        setState(() => _error = context.l10n.rprUnsupportedCode);
        return;
      }
      widget.onConfirm(RestorePayloadRepairDecision(
        payloadFingerprint: _fingerprint,
        mode: PlanningRepairMode.global,
        globalCurrency: code,
        perRowCurrency: const {},
      ));
    } else {
      for (final entry in _perRow.entries) {
        if (!isSupportedCurrency(entry.value)) {
          setState(() => _error = context.l10n.rprUnsupportedCode);
          return;
        }
      }
      widget.onConfirm(RestorePayloadRepairDecision(
        payloadFingerprint: _fingerprint,
        mode: PlanningRepairMode.perRow,
        globalCurrency: null,
        perRowCurrency: Map<String, String>.from(_perRow),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        key: const Key('restore_payload_repair_view'),
        appBar: AppHeader(title: context.l10n.rprTitle),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              context.l10n.rprIntro,
            ),
            const SizedBox(height: 16),
            SegmentedButton<PlanningRepairMode>(
              segments: [
                ButtonSegment(
                    value: PlanningRepairMode.global,
                    label: Text(context.l10n.pcrOneCurrencyForAll)),
                ButtonSegment(
                    value: PlanningRepairMode.perRow,
                    label: Text(context.l10n.rprPerItem)),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() {
                _mode = s.first;
                _error = null;
              }),
            ),
            const SizedBox(height: 16),
            if (_mode == PlanningRepairMode.global)
              TextField(
                key: const Key('restore_repair_global_field'),
                controller: _globalController,
                decoration: InputDecoration(
                  labelText: context.l10n.rprTreatAllAs,
                ),
              )
            else
              ...widget.rows.map(_perRowTile),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
            const SizedBox(height: 24),
            FilledButton(
              key: const Key('restore_repair_confirm'),
              onPressed: _confirm,
              child: Text(context.l10n.rprContinueRestore),
            ),
            const SizedBox(height: 8),
            TextButton(
              key: const Key('restore_repair_cancel'),
              onPressed: widget.onCancel,
              child: Text(context.l10n.rprCancelRestore),
            ),
          ],
        ),
      ),
    );
  }

  Widget _perRowTile(RestorePlanningRow r) {
    return ListTile(
      title: Text(r.isGoal ? context.l10n.rprGoal : context.l10n.rprBudget),
      subtitle: Text(context.l10n.rprLegacyAmount(r.legacyAmount.toString())),
      trailing: SizedBox(
        width: 96,
        child: TextField(
          key: Key('restore_repair_row_${r.id}'),
          controller: TextEditingController(text: _perRow[r.id]),
          onChanged: (v) => _perRow[r.id] = v.trim().toUpperCase(),
          decoration: InputDecoration(labelText: context.l10n.dtxCurrency),
        ),
      ),
    );
  }
}
