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
import '../capture/capture_runtime.dart';
import '../capture/manual_paste_screen.dart';
import '../capture/services/android_sms_capture_service.dart';
import 'widgets/premium_ui.dart';

TextStyle _alex(double size, FontWeight weight, double height, Color color) {
  return GoogleFonts.alexandria(
    fontSize: size,
    fontWeight: weight,
    height: height,
    color: color,
  );
}

class ListeningScreen extends ConsumerStatefulWidget {
  const ListeningScreen({super.key});

  @override
  ConsumerState<ListeningScreen> createState() => _ListeningScreenState();
}

class _ListeningScreenState extends ConsumerState<ListeningScreen> {
  StreamSubscription<String>? _sub;

  @override
  void initState() {
    super.initState();
    AndroidSmsCaptureService.instance.startListeningIfPermitted();
    _sub = CaptureRuntime.instance.confirmRequests.listen(_onTransaction);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _onTransaction(String txId) {
    if (!mounted) return;
    context.go('/onboarding/first-transaction', extra: txId);
  }

  Future<void> _skip() async {
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
        if (mounted) context.go('/onboarding/first-transaction', extra: txId);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    return PremiumBackground(
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
          child: Column(
            children: [
              const SizedBox(height: 40),
              _PulseIndicator(color: c.accent),
              const SizedBox(height: 32),
              Text(
                context.l10n.listeningTitle,
                textAlign: TextAlign.center,
                style: _alex(24, FontWeight.w800, 1.3, c.textMain),
              ),
              const SizedBox(height: 12),
              Text(
                context.l10n.listeningSubtitle,
                textAlign: TextAlign.center,
                style: _alex(14, FontWeight.w500, 1.6, c.textLight),
              ),
              const Spacer(),
              SizedBox(
                height: 52,
                width: double.infinity,
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

class _PulseIndicator extends StatefulWidget {
  const _PulseIndicator({required this.color});
  final Color color;

  @override
  State<_PulseIndicator> createState() => _PulseIndicatorState();
}

class _PulseIndicatorState extends State<_PulseIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat(reverse: true);

  late final Animation<double> _scale =
      Tween<double>(begin: 0.88, end: 1.12).animate(
    CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
  );

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: _scale,
      child: Container(
        width: 80,
        height: 80,
        decoration: BoxDecoration(
          color: widget.color.withValues(alpha: 0.15),
          shape: BoxShape.circle,
          border: Border.all(color: widget.color.withValues(alpha: 0.4), width: 2),
        ),
        child: Icon(Icons.wifi_tethering_rounded, color: widget.color, size: 36),
      ),
    );
  }
}
