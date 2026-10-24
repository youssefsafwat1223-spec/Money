import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../../core/backend/supabase_config.dart';
import '../../core/di/local_read_providers.dart';
import '../../core/session/app_session.dart';
import '../../core/utils/l10n_ext.dart';
import '../../l10n/app_localizations.dart';
import 'local_read_cleanup_notice.dart';

/// Offline local read — the minimal read-only shell.
///
/// It shows the account's existing balances and transactions from the read-only
/// handle, a clear "Offline — read only" banner with a Reconnect (sign in)
/// action, and Logout. It has no add/edit/delete/import/settings/capture control,
/// mounts none of the ordinary shell's producers (sync, timers, capture,
/// notifications, catalog) and shows no restore spinner.
class LocalReadShell extends ConsumerWidget {
  const LocalReadShell({
    super.key,
    this.onReconnect,
    this.onLogout,
    this.signOutAction,
    this.retryDeny,
  });

  /// Test seams; the defaults are the real sign-in route and logout.
  final VoidCallback? onReconnect;
  final Future<void> Function()? onLogout;
  final Future<SignOutOutcome> Function()? signOutAction;
  final Future<bool> Function()? retryDeny;

  Future<void> _logout(NavigatorState navigator, AppL10n l10n) async {
    final outcome = await (signOutAction ?? AppSession.instance.signOut)();
    if (SupabaseConfig.isConfigured) {
      try {
        await supabase.Supabase.instance.client.auth.signOut();
      } catch (_) {
        // The local sign-out already protects the device.
      }
    }
    if (outcome == SignOutOutcome.durableDenyIncomplete) {
      // Signed out and locked for this process, but the durable lock is not
      // established: say so, honestly, with a retry of only that step.
      await showSignOutIncompleteNotice(navigator, l10n, retry: retryDeny);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final snapshot = ref.watch(localReadSnapshotProvider);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(l10n.appTitle),
        actions: [
          TextButton(
            key: const Key('local_read_logout'),
            onPressed: () async {
              // This shell is disposed by the scope swap: capture first.
              final navigator = Navigator.of(context, rootNavigator: true);
              try {
                await (onLogout?.call() ?? _logout(navigator, l10n));
              } catch (_) {
                if (context.mounted) {
                  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                      SnackBar(content: Text(l10n.localReadLogoutFailed)));
                }
              }
            },
            child: Text(l10n.localReadLogout),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            key: const Key('local_read_banner'),
            width: double.infinity,
            color: theme.colorScheme.secondaryContainer,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.localReadBannerTitle,
                    style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(l10n.localReadBannerBody),
                const SizedBox(height: 8),
                FilledButton(
                  key: const Key('local_read_reconnect'),
                  onPressed: onReconnect ??
                      () => GoRouter.of(context).go('/onboarding/auth'),
                  child: Text(l10n.localReadReconnect),
                ),
              ],
            ),
          ),
          Expanded(
            child: snapshot.when(
              loading: () => const SizedBox.shrink(),
              error: (_, __) => Center(child: Text(l10n.localReadLoadError)),
              data: (data) => ListView(
                children: [
                  _Header(l10n.localReadBalancesTitle),
                  if (data.accounts.isEmpty) _Note(l10n.localReadNoAccounts),
                  for (final a in data.accounts)
                    ListTile(
                      title: Text(a.name),
                      trailing: Text('${a.balance} ${a.currency}'),
                    ),
                  _Header(l10n.localReadTransactionsTitle),
                  if (data.transactions.isEmpty)
                    _Note(l10n.localReadNoTransactions),
                  for (final t in data.transactions)
                    ListTile(
                      key: ValueKey('local_read_tx_${t.id}'),
                      title: Text(t.title),
                      subtitle: Text(t.occurredAt),
                      trailing: Text(
                          '${t.isDebit ? '-' : ''}${t.amount} ${t.currency}'),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(text, style: Theme.of(context).textTheme.titleSmall),
      );
}

class _Note extends StatelessWidget {
  const _Note(this.text);
  final String text;
  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.all(16), child: Text(text));
}
