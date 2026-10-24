import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../../core/auth/account_deletion_gateway.dart';
import '../../core/backend/supabase_config.dart';
import '../../core/di/app_providers.dart';
import '../../core/router/app_router.dart';
import '../../core/session/app_session.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/l10n_ext.dart';

enum _Phase { idle, running, accepted, failed, unconfirmed, completed }

/// Delete account: one clear action, an explicit confirmation, and an honest
/// report of what the backend achieved. The person is shown success and returned
/// to the auth screen ONLY when the gateway reports
/// [AccountDeletionCompleted]; a request that was merely accepted, still in
/// progress, or that failed is never presented as a finished deletion, and local
/// data is only reset on completion.
class DeleteAccountScreen extends ConsumerStatefulWidget {
  const DeleteAccountScreen({super.key});

  @override
  ConsumerState<DeleteAccountScreen> createState() =>
      _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends ConsumerState<DeleteAccountScreen> {
  _Phase _phase = _Phase.idle;
  bool _retryable = true;
  StreamSubscription<AccountDeletionState>? _sub;

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  Future<void> _confirmAndStart() async {
    if (_phase == _Phase.running) return;
    final l10n = context.l10n;
    final immediate = ref.read(accountDeletionGatewayProvider).deletesImmediately;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.deleteAccountConfirmTitle),
        content: Text(immediate
            ? l10n.deleteAccountConfirmBody
            : l10n.deleteAccountConfirmBodyScheduled),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.commonCancel)),
          TextButton(
              key: const Key('deleteAccountConfirm'),
              style: TextButton.styleFrom(foregroundColor: ctx.colors.danger),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l10n.deleteAccountConfirmAction)),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    _start();
  }

  void _start() {
    if (_phase == _Phase.running) return;
    setState(() => _phase = _Phase.running);
    unawaited(_sub?.cancel());
    _sub = ref.read(accountDeletionGatewayProvider).delete().listen(
      (state) {
        if (!mounted) return;
        switch (state) {
          case AccountDeletionInProgress():
            setState(() => _phase = _Phase.running);
          case AccountDeletionAccepted():
            setState(() => _phase = _Phase.accepted);
            ref.invalidate(accountDeletionStatusProvider);
          case AccountDeletionFailed(:final retryable):
            setState(() {
              _phase = _Phase.failed;
              _retryable = retryable;
            });
          case AccountDeletionCompleted():
            setState(() => _phase = _Phase.completed);
            unawaited(_finish());
        }
      },
      onError: (Object _) {
        if (!mounted) return;
        setState(() {
          _phase = _Phase.failed;
          _retryable = true;
        });
      },
      onDone: () {
        // A stream that ends while the deletion is still in progress did not
        // confirm anything: never a success.
        if (!mounted || _phase != _Phase.running) return;
        setState(() => _phase = _Phase.unconfirmed);
      },
    );
  }

  /// Completed on the server: only now is the local replica reset and the person
  /// returned to the auth screen. The reset replaces the account scope (which
  /// disposes this screen), so navigation uses the app router.
  Future<void> _finish() async {
    await AppSession.instance.resetAllLocalData(
      signOutRemote: SupabaseConfig.isConfigured
          ? supabase.Supabase.instance.client.auth.signOut
          : null,
    );
    appRouter.go('/welcome');
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    final busy = _phase == _Phase.running || _phase == _Phase.completed;
    Widget status() {
      switch (_phase) {
        case _Phase.idle:
          return const SizedBox.shrink();
        case _Phase.running:
          return Row(
            key: const Key('deleteAccountProgress'),
            children: [
              const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: AppSpacing.s2),
              Expanded(
                  child: Text(l10n.deleteAccountProgress,
                      style: AppTypography.body(c.textMain))),
            ],
          );
        case _Phase.completed:
          return Text(l10n.deleteAccountSuccess,
              key: const Key('deleteAccountSuccess'),
              style: AppTypography.bodyStrong(c.textMain));
        case _Phase.accepted:
          return Column(
            key: const Key('deleteAccountAccepted'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.deleteAccountAcceptedBody,
                  style: AppTypography.body(c.textMain)),
              const SizedBox(height: AppSpacing.s2),
              TextButton(
                key: const Key('deleteAccountDone'),
                onPressed: () => Navigator.of(context).maybePop(),
                child: Text(l10n.deleteAccountDone),
              ),
            ],
          );
        case _Phase.failed:
        case _Phase.unconfirmed:
          final failed = _phase == _Phase.failed;
          final retryable = !failed || _retryable;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                !failed
                    ? l10n.deleteAccountUnconfirmed
                    : retryable
                        ? l10n.deleteAccountFailed
                        : l10n.deleteAccountFailedFinal,
                style: AppTypography.body(c.danger),
              ),
              if (retryable) ...[
                const SizedBox(height: AppSpacing.s2),
                TextButton(
                  key: const Key('deleteAccountRetry'),
                  onPressed: _start,
                  child: Text(l10n.deleteAccountRetry),
                ),
              ],
            ],
          );
      }
    }

    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(
        backgroundColor: c.bg,
        foregroundColor: c.textMain,
        title: Text(l10n.deleteAccountTitle),
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.gutter),
        children: [
          Text(l10n.deleteAccountIntro, style: AppTypography.body(c.textMain)),
          const SizedBox(height: AppSpacing.s4),
          FilledButton(
            key: const Key('deleteAccountAction'),
            style: FilledButton.styleFrom(backgroundColor: c.danger),
            onPressed: busy || _phase == _Phase.accepted
                ? null
                : _confirmAndStart,
            child: Text(l10n.deleteAccountAction),
          ),
          const SizedBox(height: AppSpacing.s4),
          status(),
        ],
      ),
    );
  }
}
