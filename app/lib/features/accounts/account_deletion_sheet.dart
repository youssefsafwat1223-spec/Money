import 'package:flutter/material.dart';

import '../../domain/entities/account_entity.dart';
import '../../core/utils/l10n_ext.dart';
import '../../domain/usecases/account_deletion.dart';
import '../../core/theme/widgets/directional_chevron.dart';

/// MALI-016 — the dependency-aware account-deletion confirmation.
///
/// Shows exactly what deleting an account will do (detach transactions; archive
/// cards/budgets) and, for each goal and subscription, forces an explicit
/// reassign-to-a-compatible-account or archive choice. Subscriptions have NO
/// default: an active recurring obligation is never handled silently, so the
/// confirm button stays disabled until every one is resolved. Returns an
/// [AccountDeletionRequest] on confirm, or null on cancel.
class AccountDeletionSheet extends StatefulWidget {
  const AccountDeletionSheet({required this.impact, super.key});

  final AccountDeletionImpact impact;

  static Future<AccountDeletionRequest?> show(
    BuildContext context,
    AccountDeletionImpact impact,
  ) {
    return showModalBottomSheet<AccountDeletionRequest>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => AccountDeletionSheet(impact: impact),
    );
  }

  @override
  State<AccountDeletionSheet> createState() => _AccountDeletionSheetState();
}

/// null value = archive; a non-null value = successor account id.
class _AccountDeletionSheetState extends State<AccountDeletionSheet> {
  static const _archive = '__archive__';

  // Goals default to archive (progress preserved either way, safe default).
  final Map<String, String> _goalChoice = {};
  // Subscriptions have NO default — must be chosen (conservative fallback).
  final Map<String, String> _subChoice = {};

  @override
  void initState() {
    super.initState();
    for (final g in widget.impact.goals) {
      _goalChoice[g.id] = _archive;
    }
  }

  bool get _allSubscriptionsResolved =>
      widget.impact.subscriptions.every((s) => _subChoice.containsKey(s.id));

  AccountReassignmentChoice _toChoice(String value) => value == _archive
      ? const AccountReassignmentChoice.archive()
      : AccountReassignmentChoice.reassign(value);

  void _confirm() {
    final request = AccountDeletionRequest(
      accountId: widget.impact.accountId,
      goalChoices: {
        for (final e in _goalChoice.entries) e.key: _toChoice(e.value),
      },
      subscriptionChoices: {
        for (final e in _subChoice.entries) e.key: _toChoice(e.value),
      },
    );
    Navigator.of(context).pop(request);
  }

  @override
  Widget build(BuildContext context) {
    final impact = widget.impact;
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        builder: (context, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          children: [
            Text(context.l10n.afDeleteAccount,
                style: theme.textTheme.titleLarge, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            _SummaryLine(
              context.l10n.adsWillDetach(impact.transactionsToDetach),
            ),
            if (impact.cardsToArchive > 0)
              _SummaryLine(context.l10n.accWillArchiveCards(impact.cardsToArchive)),
            if (impact.budgetsToArchive > 0)
              _SummaryLine(context.l10n.accWillArchiveBudgets(impact.budgetsToArchive)),
            if (impact.goals.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(context.l10n.bdgTabGoals, style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              for (final g in impact.goals)
                _DependentDecision(
                  key: ValueKey('goal-${g.id}'),
                  dependent: g,
                  compatible: impact.compatibleSuccessors(g.currency),
                  value: _goalChoice[g.id]!,
                  archiveValue: _archive,
                  onChanged: (v) => setState(() => _goalChoice[g.id] = v),
                ),
            ],
            if (impact.subscriptions.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(context.l10n.adsSubsAndBills, style: theme.textTheme.titleMedium),
              Text(
                context.l10n.adsPickDestination,
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              for (final s in impact.subscriptions)
                _DependentDecision(
                  key: ValueKey('sub-${s.id}'),
                  dependent: s,
                  compatible: impact.compatibleSuccessors(s.currency),
                  value: _subChoice[s.id],
                  archiveValue: _archive,
                  onChanged: (v) => setState(() => _subChoice[s.id] = v),
                ),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _allSubscriptionsResolved ? _confirm : null,
              style: FilledButton.styleFrom(
                backgroundColor: theme.colorScheme.error,
              ),
              child: Text(context.l10n.afDeleteAccount),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(context.l10n.commonCancel),
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryLine extends StatelessWidget {
  const _SummaryLine(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            const DirectionalChevron(size: 18),
            const SizedBox(width: 4),
            Expanded(child: Text(text)),
          ],
        ),
      );
}

/// One goal/subscription row with a reassign-or-archive dropdown. Reassignment
/// targets are limited to currency-compatible successors.
class _DependentDecision extends StatelessWidget {
  const _DependentDecision({
    required this.dependent,
    required this.compatible,
    required this.value,
    required this.archiveValue,
    required this.onChanged,
    super.key,
  });

  final AccountDependent dependent;
  final List<AccountEntity> compatible;
  final String? value;
  final String archiveValue;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(dependent.name, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 4),
          DropdownButtonFormField<String>(
            key: ValueKey('decision-${dependent.id}'),
            initialValue: value,
            isExpanded: true,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              hintText: context.l10n.adsChoose,
            ),
            items: [
              for (final acc in compatible)
                DropdownMenuItem<String>(
                  value: acc.id,
                  child: Text(context.l10n.adsMoveTo(acc.name)),
                ),
              DropdownMenuItem<String>(
                value: archiveValue,
                child: Text(context.l10n.adsArchive),
              ),
            ],
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
          ),
        ],
      ),
    );
  }
}
