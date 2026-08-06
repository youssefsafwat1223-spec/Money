import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../core/backend/supabase_config.dart';
import '../../core/utils/l10n_ext.dart';
import '../../core/backup/backup_service.dart';
import '../../core/backup/restore_controller.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../budgets/budgets_providers.dart';
import '../dashboard/dashboard_providers.dart';
import '../goals/goals_providers.dart';
import '../transactions/transactions_providers.dart';
import 'setup_screen.dart';
import 'widgets/neon_illustration.dart';
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
    // MALI-014 §Blocker-5 — drive the truthful two-phase restore through the
    // controller: PREPARE (download/decrypt/validate, no mutation) → explicit
    // user confirmation → COMMIT (destructive mutation via the maintenance gate).
    final service = ref.read(backupServiceProvider);
    final controller = RestoreController(
      prepare: () => service.prepareRestore(passphrase: passphrase),
      mutate: (confirmation) =>
          service.commitRestore(confirmation: confirmation),
      reestablish: () => service.verifyRestoredDatabaseUsable(),
      acknowledge: (opId) =>
          service.acknowledgeRestore(operationId: opId),
    );
    try {
      await controller.beginPreparation();
      if (controller.value.phase != RestoreUiPhase.readyForConfirmation) {
        _showRestoreError(controller.value.message);
        return;
      }
      // The database is NOT touched until the user confirms this replacement.
      final confirmed = await _confirmRestore();
      if (!confirmed) {
        controller.cancel();
        if (mounted) setState(() => _busy = false);
        return;
      }
      await controller.confirm();
      if (controller.value.phase == RestoreUiPhase.completed) {
        _refreshLocalData();
        if (!mounted) return;
        if (widget.onboardingFlow) {
          _replaceWithSetup(OnboardingSetupEntry.captureGuide);
        } else {
          context.go('/data-transfer');
        }
      } else {
        _showRestoreError(controller.value.message);
      }
    } finally {
      controller.dispose();
    }
  }

  void _showRestoreError(String? message) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = message ??
          (_useRecoveryCode
              ? context.l10n.recoveryCodeIncorrect
              : context.l10n.backupPasswordIncorrect);
    });
  }

  /// The explicit final confirmation shown ONLY after preparation succeeds and
  /// BEFORE any destructive mutation. Cancelling changes nothing.
  Future<bool> _confirmRestore() async {
    if (!mounted) return false;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('تأكيد الاستعادة'),
        content: const Text(
          'ستحل النسخة الاحتياطية محل بياناتك الحالية على هذا الجهاز. '
          'لا يمكن التراجع بعد التأكيد. متابعة؟',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('استعادة'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  void _startFresh() {
    if (widget.onboardingFlow) {
      _replaceWithSetup(OnboardingSetupEntry.full);
      return;
    }
    if (mounted) context.pop();
  }

  void _replaceWithSetup(OnboardingSetupEntry entry) {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => OnboardingSetupScreen(entry: entry),
      ),
    );
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
                  Center(
                    child: const NeonIllustration(
                      icon: Icons.cloud_done_rounded,
                      size: 140,
                    )
                        .animate()
                        .fade(duration: 800.ms)
                        .scale(curve: Curves.easeOutBack),
                  ),
                  const SizedBox(height: AppSpacing.s4),
                  Text(
                    context.l10n.backupFound,
                    textAlign: TextAlign.center,
                    style: AppTypography.title2(c.textMain),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    context.l10n.restoreDesc,
                    textAlign: TextAlign.center,
                    style: AppTypography.callout(c.textLight),
                  ),
                  const SizedBox(height: AppSpacing.s4),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: c.successBg.withValues(alpha: 0.62),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: c.success.withValues(alpha: 0.18),
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.verified_user_outlined,
                            color: c.success, size: 19),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'الاستعادة تحتاج كلمة المرور أو رمز الاسترداد فقط. قرش لا يقرأ محتوى النسخة بدونهم.',
                            style: AppTypography.caption(c.textMain),
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
                    obscureText: !_useRecoveryCode,
                    autocorrect: false,
                    enableSuggestions: false,
                    textCapitalization: _useRecoveryCode
                        ? TextCapitalization.characters
                        : TextCapitalization.none,
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
                        key: const Key('restore_cta'),
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
                      widget.onboardingFlow
                          ? context.l10n.startFresh
                          : context.l10n.notNow,
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
