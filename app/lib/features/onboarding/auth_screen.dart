import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_service.dart';
import '../../core/backup/backup_service.dart';
import '../../core/di/app_providers.dart';
import '../../core/session/app_session.dart';
import '../../core/theme/app_assets.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import 'restore_prompt_screen.dart';
import 'widgets/luxe_starry_bg.dart';

/// Page 3 of the redesigned onboarding: mandatory sign-in.
///
/// Auth success only sets the identity — onboarding is finished later by the
/// setup page. If the account already has a remote backup we offer to restore
/// it before proceeding.
class OnboardingAuthScreen extends ConsumerStatefulWidget {
  const OnboardingAuthScreen({super.key});

  @override
  ConsumerState<OnboardingAuthScreen> createState() =>
      _OnboardingAuthScreenState();
}

class _OnboardingAuthScreenState extends ConsumerState<OnboardingAuthScreen> {
  bool _busyApple = false;
  bool _busyGoogle = false;

  bool get _busy => _busyApple || _busyGoogle;

  Future<void> _signIn(
    Future<AuthIdentity> Function() method, {
    required bool apple,
  }) async {
    if (_busy) return;
    setState(() => apple ? _busyApple = true : _busyGoogle = true);
    try {
      final identity = await method();
      await AppSession.instance
          .setIdentity(method: identity.method, email: identity.email);
      unawaited(
        ref
            .read(captureDeviceRegistrationServiceProvider)
            .linkToCurrentUser()
            .catchError((_) {}),
      );
      if (!mounted) return;

      var hasBackup = false;
      try {
        hasBackup = await ref.read(backupServiceProvider).hasRemoteBackup();
      } catch (_) {}
      if (!mounted) return;

      if (hasBackup) {
        await _offerRestore();
      } else {
        context.go('/onboarding/setup');
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تعذّر تسجيل الدخول. جرب تاني.')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _busyApple = false;
          _busyGoogle = false;
        });
      }
    }
  }

  Future<void> _offerRestore() async {
    final choice = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final c = ctx.colors;
        return AlertDialog(
          backgroundColor: c.surface,
          title: Text('لقينا نسخة احتياطية لحسابك',
              style: AppTypography.title2(c.textMain)),
          content: Text(
            'تحب نرجّع بياناتك من آخر نسخة، ولا تبدأ من جديد؟',
            style: AppTypography.body(c.textSecondary),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('ابدأ من جديد'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('استرجاعها'),
            ),
          ],
        );
      },
    );
    if (!mounted) return;
    if (choice == true) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const RestorePromptScreen(onboardingFlow: true),
        ),
      );
    } else {
      context.go('/onboarding/setup');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      backgroundColor: c.bg,
      body: Stack(
        children: [
          const Positioned.fill(child: LuxeStarryBackground()),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
              child: Column(
                children: [
                  const Spacer(flex: 2),
                  Image.asset(AppAssets.qirshCoinGold, width: 84, height: 84)
                      .animate()
                      .fadeIn(duration: 500.ms)
                      .scale(begin: const Offset(0.8, 0.8)),
                  const SizedBox(height: AppSpacing.s5),
                  Text('سجّل دخولك',
                      style: AppTypography.title1(c.textMain)
                          .copyWith(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 8),
                  Text(
                    'حسابك بيحمي بياناتك ويخلي كل حاجة متزامنة.',
                    textAlign: TextAlign.center,
                    style: AppTypography.body(c.textLight),
                  ),
                  const Spacer(flex: 3),
                  _appleButton(c),
                  const SizedBox(height: AppSpacing.s3),
                  _googleButton(c),
                  const SizedBox(height: AppSpacing.s5),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _appleButton(AppColors c) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: _busy
            ? null
            : () => _signIn(ref.read(authServiceProvider).signInWithApple,
                apple: true),
        style: FilledButton.styleFrom(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(54),
        ),
        icon: _busyApple
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white),
              )
            : const Icon(Icons.apple, size: 22),
        label: Text('المتابعة بحساب Apple',
            style: AppTypography.bodyStrong(Colors.white)),
      ),
    );
  }

  Widget _googleButton(AppColors c) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: _busy
            ? null
            : () => _signIn(ref.read(authServiceProvider).signInWithGoogle,
                apple: false),
        style: OutlinedButton.styleFrom(
          foregroundColor: c.textMain,
          minimumSize: const Size.fromHeight(54),
          side: BorderSide(color: c.border),
        ),
        icon: _busyGoogle
            ? SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: c.textMain),
              )
            : const Icon(Icons.g_mobiledata_rounded, size: 28),
        label: Text('المتابعة بحساب Google',
            style: AppTypography.bodyStrong(c.textMain)),
      ),
    );
  }
}
