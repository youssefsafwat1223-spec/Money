import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/backend/supabase_config.dart';
import '../../core/utils/l10n_ext.dart';
import '../../core/backup/backup_service.dart';
import '../../core/session/app_session.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../budgets/budgets_providers.dart';
import '../dashboard/dashboard_providers.dart';
import '../goals/goals_providers.dart';
import '../transactions/transactions_providers.dart';
import 'widgets/premium_ui.dart';

class RestorePromptScreen extends ConsumerStatefulWidget {
  const RestorePromptScreen({super.key, required this.onboardingFlow});

  final bool onboardingFlow;

  @override
  ConsumerState<RestorePromptScreen> createState() =>
      _RestorePromptScreenState();
}

class _RestorePromptScreenState extends ConsumerState<RestorePromptScreen> {
  final _passphrase = TextEditingController();
  bool _busy = false;
  bool _useRecoveryCode = false;
  String? _error;

  @override
  void dispose() {
    _passphrase.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    final passphrase = _passphrase.text.trim();
    if (_busy || passphrase.length < 6) {
      setState(() => _error = context.l10n.enterPasswordOrRecoveryCodeError);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(backupServiceProvider)
          .restoreFromBackup(passphrase: passphrase);
      _refreshLocalData();
      if (widget.onboardingFlow) {
        await AppSession.instance.finishOnboarding();
      }
      if (!mounted) return;
      context.go(widget.onboardingFlow ? '/' : '/backup');
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _useRecoveryCode
            ? context.l10n.recoveryCodeIncorrect
            : context.l10n.backupPasswordIncorrect;
      });
    }
  }

  Future<void> _startFresh() async {
    if (widget.onboardingFlow) {
      await AppSession.instance.finishOnboarding();
      if (mounted) context.go('/');
      return;
    }
    if (mounted) context.pop();
  }

  void _refreshLocalData() {
    ref.invalidate(backupStatusProvider);
    ref.invalidate(dashboardDataProvider);
    ref.invalidate(transactionsListProvider);
    ref.invalidate(billsViewProvider);
    ref.invalidate(budgetsViewProvider);
    ref.invalidate(goalsListProvider);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final actionForeground = maliPrimaryActionForeground(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: widget.onboardingFlow ? Colors.transparent : c.bg,
      body: SafeArea(
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 680),
            margin: const EdgeInsets.all(AppSpacing.gutter),
            padding: const EdgeInsets.all(AppSpacing.gutter),
            decoration: BoxDecoration(
              color: c.bg,
              borderRadius: BorderRadius.circular(30),
              border: Border.all(color: c.border),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.55 : 0.18),
                  blurRadius: 36,
                  spreadRadius: -16,
                  offset: const Offset(0, 18),
                ),
              ],
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Center(
                    child: Container(
                      width: 44,
                      height: 5,
                      margin: const EdgeInsets.only(bottom: AppSpacing.s4),
                      decoration: BoxDecoration(
                        color: c.border,
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      gradient: c.primaryGradient,
                      borderRadius: BorderRadius.circular(26),
                    ),
                    child: Column(
                      children: [
                        Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.08),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.12),
                            ),
                          ),
                          child: const Icon(
                            Icons.lock_reset_rounded,
                            color: Colors.white,
                            size: 32,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          context.l10n.backupFound,
                          textAlign: TextAlign.center,
                          style: AppTypography.title2(Colors.white),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          context.l10n.restoreDesc,
                          textAlign: TextAlign.center,
                          style: AppTypography.footnote(
                            Colors.white.withValues(alpha: 0.84),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.s5),
                  Text(
                    _useRecoveryCode
                        ? context.l10n.recoveryCodeLabel
                        : context.l10n.backupPasswordLabel,
                    style: AppTypography.subhead(c.textLight),
                  ),
                  const SizedBox(height: AppSpacing.s2),
                  TextField(
                    controller: _passphrase,
                    obscureText: true,
                    style: AppTypography.body(c.textMain),
                    decoration: InputDecoration(
                      errorText: _error,
                      errorStyle: AppTypography.footnote(c.danger),
                      hintText: _useRecoveryCode
                          ? context.l10n.recoveryCodeHint
                          : context.l10n.backupPasswordHint,
                      hintStyle: AppTypography.callout(
                        c.textLight.withValues(alpha: 0.55),
                      ),
                      filled: true,
                      fillColor: isDark
                          ? Colors.white.withValues(alpha: 0.05)
                          : c.surface2.withValues(alpha: 0.5),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide(color: c.border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide(
                          color: c.border.withValues(alpha: 0.7),
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide(color: c.primary, width: 2),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.s2),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton(
                      onPressed: () {
                        setState(() {
                          _useRecoveryCode = !_useRecoveryCode;
                          _error = null;
                          _passphrase.clear();
                        });
                      },
                      child: Text(
                        _useRecoveryCode
                            ? context.l10n.useBackupPassword
                            : context.l10n.useRecoveryCode,
                        style: AppTypography.caption(c.primary),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.s4),
                  SizedBox(
                    height: 52,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: maliPrimaryActionGradient(context),
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: c.accent.withValues(alpha: 0.25),
                            blurRadius: 15,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: ElevatedButton(
                        onPressed: _busy ? null : _restore,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.transparent,
                          shadowColor: Colors.transparent,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: _busy
                            ? SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  color: actionForeground,
                                ),
                              )
                            : Text(
                                context.l10n.restore,
                                style:
                                    AppTypography.bodyStrong(actionForeground),
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.s2),
                  TextButton(
                    onPressed: _busy ? null : _startFresh,
                    child: Text(
                      widget.onboardingFlow ? context.l10n.startFresh : context.l10n.notNow,
                      style: AppTypography.subhead(c.textLight),
                    ),
                  ),
                  if (!SupabaseConfig.isConfigured) ...[
                    const SizedBox(height: AppSpacing.s2),
                    Text(
                      context.l10n.restoreNotEnabled,
                      textAlign: TextAlign.center,
                      style: AppTypography.caption(c.textLight),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
