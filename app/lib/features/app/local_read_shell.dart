import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../../core/auth/auth_coordinator.dart';
import '../../core/auth/auth_diagnostics.dart';
import '../../core/backend/supabase_config.dart';
import '../../core/di/local_read_providers.dart';
import '../../core/session/app_session.dart';
import '../../core/startup/automatic_session_recovery.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/qirsh_visuals.dart';
import '../../core/theme/widgets/app_toast.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/l10n_ext.dart';
import '../../l10n/app_localizations.dart';
import '../common/app_card.dart';
import '../common/app_header.dart';
import 'app_boot_loader.dart';
import 'local_read_cleanup_notice.dart';

/// Offline local read — the minimal read-only shell.
///
/// It shows the account's existing balances and transactions from the read-only
/// handle, a clear "Offline — read only" banner with a Reconnect (sign in)
/// action, and Logout. It has no add/edit/delete/import/settings/capture control,
/// mounts none of the ordinary shell's producers (sync, timers, capture,
/// notifications, catalog). The initial recovery attempt has a short branded
/// loading window before the read-only controls become available.
/// The stored UTC timestamp [raw] in the device's local time, formatted like
/// the ordinary shell ("28 أكتوبر 2026، 4:47 ص" / "October 28, 2026, 4:47 AM");
/// an unparseable value is shown as stored.
String _occurredAtLabel(String raw, BuildContext context) {
  final dt = DateTime.tryParse(raw);
  if (dt == null) return raw;
  final sep =
      Localizations.localeOf(context).languageCode == 'en' ? ', ' : '، ';
  return '${Formatters.fullDate(dt, context)}$sep${Formatters.time(dt, context)}';
}

class LocalReadShell extends ConsumerStatefulWidget {
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

  @override
  ConsumerState<LocalReadShell> createState() => _LocalReadShellState();
}

class _LocalReadShellState extends ConsumerState<LocalReadShell> {
  Timer? _recoveryDeadline;
  bool _showRecoveryLoader = false;

  @override
  void initState() {
    super.initState();
    final recovery = AutomaticSessionRecovery.active;
    if (recovery == null) return;

    _showRecoveryLoader = true;
    // Show at most one short loader per entry into local read. Retries and
    // backoff must never hide data or the Reconnect action again.
    _recoveryDeadline = Timer(const Duration(milliseconds: 1500), _showLocalRead);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Bootstrap starts recovery after the first frame. Check on the next
      // event-loop turn so its callback has had a chance to start the attempt.
      unawaited(Future<void>(() async {
        if (!mounted) return;
        await recovery.quiesced();
        _showLocalRead();
      }));
    });
  }

  void _showLocalRead() {
    _recoveryDeadline?.cancel();
    if (mounted && _showRecoveryLoader) {
      setState(() => _showRecoveryLoader = false);
    }
  }

  @override
  void dispose() {
    _recoveryDeadline?.cancel();
    super.dispose();
  }

  Future<void> _logout(NavigatorState navigator, AppL10n l10n) async {
    final outcome = await (widget.signOutAction ?? AppSession.instance.signOut)();
    if (SupabaseConfig.isConfigured) {
      try {
        // ASR §4.9: durable removal first, then the server revocation.
        await AuthCoordinator.logout(supabase.Supabase.instance.client.auth);
      } catch (_) {
        // The local sign-out already protects the device.
      }
    }
    if (outcome == SignOutOutcome.durableDenyIncomplete) {
      // Signed out and locked for this process, but the durable lock is not
      // established: say so, honestly, with a retry of only that step.
      await showSignOutIncompleteNotice(navigator, l10n, retry: widget.retryDeny);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_showRecoveryLoader) return const Scaffold(body: AppBootLoader());
    final l10n = context.l10n;
    final snapshot = ref.watch(localReadSnapshotProvider);
    final c = context.colors;
    return Scaffold(
      appBar: AppHeader(
        showBack: false,
        title: l10n.appTitle,
        action:
          TextButton(
            key: const Key('local_read_logout'),
            onPressed: () async {
              // This shell is disposed by the scope swap: capture first.
              final navigator = Navigator.of(context, rootNavigator: true);
              try {
                await (widget.onLogout?.call() ?? _logout(navigator, l10n));
              } catch (_) {
                if (context.mounted) {
                  AppToast.showError(context, l10n.localReadLogoutFailed);
                }
              }
            },
            child: Text(l10n.localReadLogout),
          ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          AppCard(
            key: const Key('local_read_banner'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const QirshIllustration(name: 'privacy', width: 72, height: 64),
                  const SizedBox(width: 12),
                  Expanded(child: Text(l10n.localReadBannerTitle,
                    style: AppTypography.bodyStrong(c.textPrimary))),
                ]),
                const SizedBox(height: 12),
                Text(l10n.localReadBannerBody,
                    style: AppTypography.body(c.textSecondary)),
                // Beta 1 diagnostic: why automatic recovery stopped
                // (constants only, never an identifier).
                if (kDebugMode) ValueListenableBuilder<String?>(
                  valueListenable: AutomaticSessionRecovery.diagnostic,
                  builder: (_, code, __) => code == null
                      ? const SizedBox.shrink()
                      : Text('ASR: $code',
                          key: const Key('local_read_asr_diag'),
                          style: AppTypography.caption(c.textSecondary)),
                ),
                // Beta 1 diagnostic: the recent refresh attempts, newest
                // first (constants, durations and local times only).
                if (kDebugMode) ValueListenableBuilder<List<String>>(
                  valueListenable: AuthDiagnostics.entries,
                  builder: (_, lines, __) => lines.isEmpty
                      ? const SizedBox.shrink()
                      : SelectableText(lines.take(8).join('\n'),
                          key: const Key('local_read_auth_trail'),
                          style: AppTypography.caption(c.textSecondary)),
                ),
                const SizedBox(height: 16),
                SizedBox(width: double.infinity, child: FilledButton(
                  key: const Key('local_read_reconnect'),
                  style: FilledButton.styleFrom(
                    backgroundColor: c.ink, foregroundColor: c.onInk),
                  onPressed: widget.onReconnect ??
                      () => GoRouter.of(context).go('/onboarding/auth'),
                  child: Text(l10n.localReadReconnect),
                )),
              ],
            ),
          ),
          const SizedBox(height: 8),
          ...snapshot.when<List<Widget>>(
              loading: () => const [SizedBox.shrink()],
              error: (_, __) => [AppCard(
                child: Row(children: [
                  Icon(AppLucideIcons.alertCircle, color: c.danger, size: 22),
                  const SizedBox(width: 12),
                  Expanded(child: Text(l10n.localReadLoadError,
                      style: AppTypography.body(c.textPrimary))),
                ]),
              )],
              data: (data) => [
                  _Header(l10n.localReadBalancesTitle),
                  if (data.accounts.isEmpty) _Note(l10n.localReadNoAccounts),
                  if (data.accounts.isNotEmpty) AppCard(
                    padding: EdgeInsets.zero,
                    child: Column(children: [for (final a in data.accounts)
                    _SnapshotRow(
                      title: a.name,
                      amount: '${a.balance} ${a.currency}',
                      amountColor: c.textPrimary,
                    ),
                  ])),
                  _Header(l10n.localReadTransactionsTitle),
                  if (data.transactions.isEmpty)
                    _Note(l10n.localReadNoTransactions),
                  for (final t in data.transactions) AppCard(
                    padding: EdgeInsets.zero,
                    margin: const EdgeInsets.only(bottom: 8),
                    child: _SnapshotRow(
                      key: ValueKey('local_read_tx_${t.id}'),
                      title: t.title,
                      subtitle: _occurredAtLabel(t.occurredAt, context),
                      amount: '${t.isDebit ? '-' : ''}${t.amount} ${t.currency}',
                      amountColor: t.isDebit ? c.textPrimary : c.success,
                    ),
                  ),
                ],
            ),
        ],
      ),
    );
  }
}

class _SnapshotRow extends StatelessWidget {
  const _SnapshotRow({super.key, required this.title, required this.amount,
    required this.amountColor, this.subtitle});
  final String title;
  final String amount;
  final Color amountColor;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final amountStyle = AppTypography.bodyStrong(amountColor);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: LayoutBuilder(builder: (context, constraints) {
        final measurement = TextPainter(text: TextSpan(text: amount, style: amountStyle),
          textDirection: TextDirection.ltr, textScaler: MediaQuery.textScalerOf(context))
          ..layout();
        final stacked = measurement.width > constraints.maxWidth * .45;
        measurement.dispose();
        final label = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: AppTypography.body(c.textPrimary)),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle!, style: AppTypography.caption(c.textSecondary)),
          ],
        ]);
        final value = Text(amount, textDirection: TextDirection.ltr, style: amountStyle);
        return stacked
            ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                label, const SizedBox(height: 8), value,
              ])
            : Row(children: [Expanded(child: label), const SizedBox(width: 12), value]);
      }),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 16, 0, 8),
        child: Text(text, style: AppTypography.bodyStrong(context.colors.textPrimary)),
      );
}

class _Note extends StatelessWidget {
  const _Note(this.text);
  final String text;
  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.all(16), child: Text(text));
}
