import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../../core/auth/auth_service.dart';
import '../../core/backend/supabase_config.dart';
import '../../core/di/app_providers.dart';
import '../../core/session/app_session.dart';
import '../../core/theme/app_assets.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/premium_glass_container.dart';
import '../../core/utils/l10n_ext.dart';
import 'widgets/word_reveal_text.dart';
import '../../core/theme/widgets/app_toast.dart';
import '../../core/utils/app_lucide_icons.dart';

/// Same flat navy the native launch screen uses (`flutter_native_splash.yaml`,
/// `color: "#021B79"`) and the rest of the pre-dashboard onboarding sequence.
const _authBlue = AppBrandBlue.brand;

/// The deep navy the hand/jar hero art (`banner_onboarding_1.jpg`) fades into.
/// The screen blends from this at the top to [_authBlue] at the buttons so the
/// hero melts seamlessly into the background.
const _authDeepNavy = Color(0xFF031322);

/// Page 3 of the redesigned onboarding: mandatory sign-in.
///
/// Same flat navy background and small fixed logo as the rest of the
/// onboarding sequence — no photo backdrop.
///
/// Auth success only sets the identity — onboarding is finished later by the
/// setup page. Legacy backup restore remains available later from Data Transfer
/// and no longer interrupts the first authenticated session.
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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Warm the hero art so it doesn't flash in on first frame.
    precacheImage(const AssetImage(AppAssets.authHero), context);
  }

  Future<void> _signIn(
    Future<AuthIdentity> Function() method, {
    required bool apple,
  }) async {
    if (_busy) return;
    HapticFeedback.lightImpact();
    setState(() => apple ? _busyApple = true : _busyGoogle = true);
    try {
      final identity = await method();
      await AppSession.instance.setIdentity(
        method: identity.method,
        email: identity.email,
        userId: identity.userId,
      );
      if (SupabaseConfig.isConfigured) {
        await AppSession.instance.reconcileAccountOnboarding(
          supabase.Supabase.instance.client,
        );
        if (!mounted) return;
        unawaited(
          ref
              .read(captureDeviceRegistrationServiceProvider)
              .linkToCurrentUser()
              .catchError((_) {}),
        );
      }
      if (!mounted) return;
      if (AppSession.instance.hasCompletedOnboarding) {
        context.go('/');
        return;
      }

      context.go('/onboarding/setup');
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint(
          '[Auth] interactive sign-in failed: '
          '${error.runtimeType}: $error',
        );
        debugPrintStack(stackTrace: stackTrace);
      }
      if (mounted) {
        AppToast.showError(context, context.l10n.authSignInError);
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

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: _authDeepNavy,
        body: Stack(
          children: [
            // Navy gradient behind everything: the hero's own deep navy up top,
            // landing on the brand navy where the buttons sit.
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [_authDeepNavy, _authBlue],
                    stops: [0.42, 1.0],
                  ),
                ),
              ),
            ),
            Column(
              children: [
                // Tight-cropped hand/jar hero (ends just below the emblem in the
                // image's own deep navy). Fills the band above the content; its
                // navy foot fades into the matching background so there's no
                // seam and no empty navy gap.
                Expanded(
                  child: ShaderMask(
                    shaderCallback: (rect) => const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.white, Colors.white, Colors.transparent],
                      stops: [0.0, 0.9, 1.0],
                    ).createShader(rect),
                    blendMode: BlendMode.dstIn,
                    child: const Image(
                      image: AssetImage(AppAssets.authHero),
                      fit: BoxFit.cover,
                      alignment: Alignment.topCenter,
                    ),
                  ),
                ),
                // Title + subtitle + sign-in card, in the navy below the hero.
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.gutter,
                      0,
                      AppSpacing.gutter,
                      AppSpacing.s5,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        WordRevealText(
                          l10n.authTitle,
                          textAlign: TextAlign.center,
                          style: AppTypography.custom(
                            size: 28,
                            weight: FontWeight.w700,
                            height: 1.14,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          l10n.authSubtitle,
                          textAlign: TextAlign.center,
                          style: AppTypography.body(
                            Colors.white.withValues(alpha: 0.74),
                          ).copyWith(height: 1.6),
                        ),
                        const SizedBox(height: AppSpacing.s6),
                        PremiumGlassContainer(
                          blurSigma: 25,
                          noiseOpacity: 0.05,
                          backgroundColor: Colors.white.withValues(alpha: 0.08),
                          borderColor: Colors.white.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(32),
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _appleButton(c),
                              const SizedBox(height: 16),
                              _googleButton(c),
                              const SizedBox(height: 24),
                              Wrap(
                                alignment: WrapAlignment.center,
                                spacing: 4,
                                runSpacing: 6,
                                children: [
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(
                                        AppLucideIcons.shieldCheck,
                                        size: 14,
                                        color: Colors.white54,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        l10n.authTrustLocalEncryption,
                                        style:
                                            AppTypography.micro(Colors.white54),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(width: 12),
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(
                                        AppLucideIcons.smartphone,
                                        size: 14,
                                        color: Colors.white54,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        l10n.authTrustOnDevice,
                                        style:
                                            AppTypography.micro(Colors.white54),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              const SizedBox(height: 16),
                              Text(
                                l10n.authTermsNotice,
                                textAlign: TextAlign.center,
                                style: AppTypography.micro(
                                  Colors.white.withValues(alpha: 0.48),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _appleButton(AppColors c) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: _busy
            ? null
            : () => _signIn(
                  ref.read(authServiceProvider).signInWithApple,
                  apple: true,
                ),
        style: FilledButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: Colors.black,
          minimumSize: const Size.fromHeight(54),
          shape: const StadiumBorder(),
        ),
        icon: _busyApple
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.black,
                ),
              )
            : const Icon(Icons.apple, size: 24),
        label: Text(
          context.l10n.authAppleCta,
          style: AppTypography.bodyStrong(Colors.black),
        ),
      ),
    );
  }

  Widget _googleButton(AppColors c) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: _busy
            ? null
            : () => _signIn(
                  ref.read(authServiceProvider).signInWithGoogle,
                  apple: false,
                ),
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          backgroundColor: Colors.transparent,
          minimumSize: const Size.fromHeight(54),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.3)),
          shape: const StadiumBorder(),
        ),
        icon: _busyGoogle
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Color(0xFF151515),
                ),
              )
            : const Icon(Icons.g_mobiledata_rounded, size: 28),
        label: Text(
          context.l10n.authGoogleCta,
          style: AppTypography.bodyStrong(Colors.white),
        ),
      ),
    );
  }
}
