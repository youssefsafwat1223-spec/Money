import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/backend/supabase_config.dart';
import '../../core/backup/backup_service.dart';
import '../../core/session/app_session.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/utils/l10n_ext.dart';
import '../capture/manual_paste_screen.dart';
import '../capture/services/captured_message_processor.dart';
import '../capture/services/native_capture_bridge.dart';
import 'onboarding_options.dart';
import 'widgets/premium_ui.dart';

TextStyle _alex(double size, FontWeight weight, double height, Color color) {
  return GoogleFonts.alexandria(
    fontSize: size,
    fontWeight: weight,
    height: height,
    color: color,
  );
}

class IosShortcutVerifyScreen extends ConsumerStatefulWidget {
  const IosShortcutVerifyScreen({super.key});

  @override
  ConsumerState<IosShortcutVerifyScreen> createState() =>
      _IosShortcutVerifyScreenState();
}

class _IosShortcutVerifyScreenState
    extends ConsumerState<IosShortcutVerifyScreen> with WidgetsBindingObserver {
  Timer? _timer;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _poll();
  }

  Future<void> _poll() async {
    if (_checking || !mounted) return;
    _checking = true;
    try {
      final messages = await NativeCaptureBridge.consumePendingSharedMessages();
      for (final msg in messages) {
        if (!mounted) return;
        final result = await CapturedMessageProcessor.process(
          rawMessage: msg.text,
          senderId: msg.sender,
          showNotifications: false,
        );
        final txId = result.transactionId;
        if (txId != null && mounted) {
          context.go('/onboarding/first-transaction', extra: txId);
          return;
        }
      }
    } finally {
      _checking = false;
    }
  }

  Future<void> _skip() async {
    _timer?.cancel();
    if (SupabaseConfig.isConfigured) {
      try {
        final hasBackup = await ref.read(backupServiceProvider).hasRemoteBackup();
        if (mounted && hasBackup) {
          context.push('/onboarding/restore');
          return;
        }
      } catch (_) {}
    }
    await AppSession.instance.finishOnboarding();
    if (mounted) context.go('/');
  }

  void _paste() {
    ManualPasteScreen.showSheet(
      context,
      onTransactionAdded: (txId) {
        _timer?.cancel();
        if (mounted) context.go('/onboarding/first-transaction', extra: txId);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final currencyCode = ref.watch(onboardingSelectionProvider).currencyCode;
    final keyword = currencyKeywords(currencyCode).first;

    return PremiumBackground(
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 40),
              Container(
                width: 72,
                height: 72,
                alignment: Alignment.center,
                margin: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
                decoration: BoxDecoration(
                  color: c.accent.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                  border: Border.all(color: c.accent.withValues(alpha: 0.3), width: 2),
                ),
                child: Icon(Icons.ios_share_rounded, color: c.accent, size: 32),
              ),
              const SizedBox(height: 28),
              Text(
                context.l10n.shortcutVerifyTitle,
                textAlign: TextAlign.center,
                style: _alex(22, FontWeight.w800, 1.3, c.textMain),
              ),
              const SizedBox(height: 12),
              Text(
                context.l10n.shortcutVerifyBody,
                textAlign: TextAlign.center,
                style: _alex(14, FontWeight.w500, 1.6, c.textLight),
              ),
              const SizedBox(height: 12),
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: c.accent.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(99),
                    border: Border.all(color: c.accent.withValues(alpha: 0.24)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        context.l10n.filterKeywordsLabel,
                        style: _alex(11, FontWeight.w700, 1.2, c.textLight),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        keyword,
                        style: _alex(12, FontWeight.w800, 1.2, c.accent),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 32),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: c.accent,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    context.l10n.shortcutVerifyWaiting,
                    style: _alex(13, FontWeight.w600, 1.2, c.textLight),
                  ),
                ],
              ),
              const Spacer(),
              OutlinedButton(
                onPressed: () => context.pop(),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                  side: BorderSide(color: c.border),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                ),
                child: Text(
                  context.l10n.recheckSetup,
                  style: _alex(14, FontWeight.w700, 1.2, c.textMain),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 52,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: maliPrimaryActionGradient(context),
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: c.accent.withValues(alpha: 0.22),
                        blurRadius: 14,
                        offset: const Offset(0, 5),
                      ),
                    ],
                  ),
                  child: ElevatedButton(
                    onPressed: _paste,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.transparent,
                      shadowColor: Colors.transparent,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                    ),
                    child: Text(
                      context.l10n.pasteMessageInstead,
                      style: _alex(14, FontWeight.w800, 1.2,
                          maliPrimaryActionForeground(context)),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _skip,
                child: Text(
                  context.l10n.skipForNow,
                  style: _alex(13, FontWeight.w700, 1.2, c.textLight),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
