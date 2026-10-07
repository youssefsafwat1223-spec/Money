import 'package:flutter/material.dart';

import '../../core/session/unsynced_inventory.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/navy_sheet_theme.dart';
import '../../core/utils/l10n_ext.dart';

/// What the person chose in the sign-out sheet (SYNC-Q8).
enum SignOutChoice {
  /// The DEFAULT: lock the encrypted replica and keep everything on the device.
  keepData,

  /// The separate, destructive choice: delete this account's replica from the
  /// device (manifest §4.4).
  removeData,
}

/// The unsynced work, as one readable list ("3 transaction changes, 1 card ...").
String unsyncedItemsList(BuildContext context, UnsyncedInventory inv) {
  final l10n = context.l10n;
  final parts = <String>[];
  if (inv.ledgerOutbox > 0) {
    parts.add(l10n.setUnsyncedLedger(inv.ledgerOutbox));
  }
  if (inv.planningOutbox > 0) {
    parts.add(l10n.setUnsyncedPlanning(inv.planningOutbox));
  }
  if (inv.smartInboxPending > 0) {
    parts.add(l10n.setUnsyncedInbox(inv.smartInboxPending));
  }
  if (inv.localOnlyCards > 0) {
    parts.add(l10n.setUnsyncedCards(inv.localOnlyCards));
  }
  // Audit H-3: rows that never reached the cloud and are not even queued.
  if (inv.unprovenFinancialRows > 0) {
    parts.add(l10n.setUnsyncedUnproven(inv.unprovenFinancialRows));
  }
  if (inv.unresolvedConflicts > 0) {
    parts.add(l10n.setUnsyncedConflicts(inv.unresolvedConflicts));
  }
  return parts.join(l10n.setListSeparator);
}

/// The sign-out sheet. "Sign out and keep encrypted data" is the primary,
/// default action (SYNC-Q8); "Sign out and remove data from this device" is a
/// separate destructive choice. Unsynced work only WARNS (SYNC-Q2): it never
/// blocks either action, and keeping is what happens by default. Null when the
/// sheet is dismissed.
Future<SignOutChoice?> showSignOutSheet(
  BuildContext context, {
  UnsyncedInventory? pending,
}) {
  final c = context.colors;
  final l10n = context.l10n;
  final unsynced = pending != null && pending.hasPendingUserData;
  return showModalBottomSheet<SignOutChoice>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => navySheetTheme(
      Directionality(
        textDirection: Directionality.of(sheetContext),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            AppSpacing.s2,
            AppSpacing.gutter,
            AppSpacing.s6,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l10n.setSignOut,
                    style: AppTypography.sectionTitle(c.textMain)),
                if (unsynced) ...[
                  const SizedBox(height: AppSpacing.s3),
                  Text(
                    l10n.signOutUnsyncedKeepBody(
                        unsyncedItemsList(sheetContext, pending)),
                    key: const Key('signOutUnsyncedWarning'),
                    style: AppTypography.body(c.textMain),
                  ),
                ],
                const SizedBox(height: AppSpacing.s4),
                FilledButton(
                  key: const Key('signOutKeepData'),
                  onPressed: () =>
                      Navigator.of(sheetContext).pop(SignOutChoice.keepData),
                  child: Text(l10n.signOutKeepData),
                ),
                const SizedBox(height: AppSpacing.s2),
                Text(l10n.signOutKeepDataHint,
                    style: AppTypography.caption(c.textLight)),
                const SizedBox(height: AppSpacing.s5),
                OutlinedButton(
                  key: const Key('signOutRemoveData'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: c.danger,
                    side: BorderSide(color: c.danger),
                  ),
                  onPressed: () =>
                      Navigator.of(sheetContext).pop(SignOutChoice.removeData),
                  child: Text(l10n.signOutRemoveData),
                ),
                const SizedBox(height: AppSpacing.s2),
                Text(l10n.signOutRemoveDataHint,
                    style: AppTypography.caption(c.textLight)),
                const SizedBox(height: AppSpacing.s3),
                TextButton(
                  onPressed: () => Navigator.of(sheetContext).pop(),
                  child: Text(l10n.setCancel),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// The explicit confirmation before removal; it lists any unsynced work that the
/// removal will lose. True only on an explicit confirm.
Future<bool> confirmRemoveData(
  BuildContext context, {
  UnsyncedInventory? pending,
}) async {
  final l10n = context.l10n;
  final unsynced = pending != null && pending.hasPendingUserData;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(l10n.removeDataTitle),
      content: Text(
        unsynced
            ? '${l10n.removeDataBody}\n\n'
                '${l10n.removeDataUnsyncedBody(unsyncedItemsList(ctx, pending))}'
            : l10n.removeDataBody,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(l10n.setCancel),
        ),
        TextButton(
          key: const Key('removeDataConfirm'),
          style: TextButton.styleFrom(foregroundColor: ctx.colors.danger),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(l10n.removeDataAction),
        ),
      ],
    ),
  );
  return confirmed == true;
}
