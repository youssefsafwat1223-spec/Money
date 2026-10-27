import 'widgets/onboarding_language_button.dart';
import '../../core/session/admission_authority.dart';

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../../core/auth/auth_service.dart';
import '../../core/auth/supabase_auth_service.dart' show AuthCancelledException;
import '../../core/backend/supabase_config.dart';
import '../../core/privacy/cloud_egress_gate.dart' show EgressDeniedException;
import '../../core/privacy/consent_authority.dart' show ConsentAuthority;
import '../../core/router/app_router.dart';
import '../../core/session/app_session.dart';
import '../../core/theme/app_assets.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/premium_glass_container.dart';
import '../../core/utils/l10n_ext.dart';
import 'widgets/word_reveal_text.dart';
import '../../core/theme/widgets/app_toast.dart';
import '../../core/utils/app_lucide_icons.dart';

/// The deep navy of the hero art's lower half (`banner_onboarding_1.jpg`),
/// shown behind it while it loads.
const _authDeepNavy = Color(0xFF031322);

/// Pixel size of the full-page hero (`banner_onboarding_1.jpg`) and where its
/// emblem's gold ring ends, as a fraction of its height.
const _heroSize = Size(600, 1200);
const _heroEmblemBottom = 0.58;

/// Whether this platform can complete Sign in with Apple.
///
/// V1 is iOS-only by decision (`Qirsh Production/17_Apple_Production/`). The
/// implementation uses the NATIVE flow — `SignInWithApple.getAppleIDCredential`
/// with no `webAuthenticationOptions`, exchanged via `signInWithIdToken` — which
/// cannot complete on Android. Showing the button there offers a control that
/// always fails.
///
/// Supporting Android would need a Services ID, the Supabase callback URL as a
/// Return URL, and `webAuthenticationOptions` in the credential request. None of
/// those exist, so the button is gated rather than half-supported.
///
/// Uses `defaultTargetPlatform` rather than `dart:io` so a test can drive it
/// through `debugDefaultTargetPlatformOverride`.
@visibleForTesting
bool get appleSignInSupported => defaultTargetPlatform == TargetPlatform.iOS;

String _egressCode(String reason) {
  final tag = ConsentAuthority.egressFreezeTag;
  return reason == 'frozen' && tag.isNotEmpty
      ? 'EgressDenied:frozen/$tag'
      : 'EgressDenied:$reason';
}

/// A short, non-sensitive reason code for a failed sign-in, appended to the
/// generic toast so a field report can be diagnosed: the exception type and, for
/// an egress refusal, the gate's reason string. Never the exception message, a
/// token, an email or a uid. The Supabase client wraps a refused request in its
/// own exception type, so the reason is read from the stable `egress_denied:`
/// prefix that [EgressDeniedException] puts in its message (reason strings are
/// lower-case identifiers).
@visibleForTesting
String signInFailureCode(Object error) {
  if (error is EgressDeniedException) return _egressCode(error.reason);
  final wrapped = RegExp(r'egress_denied:([a-z_]+)').firstMatch('$error');
  if (wrapped != null) return _egressCode(wrapped.group(1)!);
  return error.runtimeType.toString();
}

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

  bool get _busy => _busyApple;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Warm the hero art so it doesn't flash in on first frame.
    precacheImage(const AssetImage(AppAssets.authHero), context);
  }

  Future<void> _signIn(Future<AuthIdentity> Function() method) async {
    if (_busy) return;
    HapticFeedback.lightImpact();
    setState(() => _busyApple = true);
    // F2: the attempt is captured BEFORE the provider is awaited. If Remove data
    // is accepted while the provider sheet is open, this attempt is stale and
    // cannot authorize (re)creating anything once it completes.
    final attempt = AppSession.instance.beginAuthAttempt();
    try {
      final identity = await method();
      if (SupabaseConfig.isConfigured && identity.isCurrent == null) {
        throw const StaleAdmissionException();
      }
      // Admission publishes capture ownership through bootstrap's service for
      // the newly committed account scope. This screen's provider graph is
      // retired by that swap, so it must not retain a database-bound service.
      await AppSession.instance.setIdentity(
        method: identity.method,
        email: identity.email,
        userId: identity.userId,
        attempt: attempt,
        sessionCurrent: identity.isCurrent,
      );
      if (SupabaseConfig.isConfigured) {
        await AppSession.instance.reconcileAccountOnboarding(
          supabase.Supabase.instance.client,
        );
      }
      if (AppSession.instance.hasCompletedOnboarding) {
        appRouter.go('/');
        return;
      }

      appRouter.go('/onboarding/setup');
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint(
          '[Auth] interactive sign-in failed: '
          '${error.runtimeType}: $error',
        );
        debugPrintStack(stackTrace: stackTrace);
      }
      if (mounted) {
        // A CONFIGURATION failure is permanent: "try again" would be a lie the
        // user could follow forever. Surface the service's own message for
        // those; keep the generic retry copy for transient failures.
        if (error is AuthCancelledException) {
          // The user closed the sheet. Nothing failed; say nothing.
        } else {
          AppToast.showError(
            context,
            '${context.l10n.authSignInError} (E: ${signInFailureCode(error)})',
          );
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _busyApple = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: _authDeepNavy,
        body: Stack(
          children: [
            Column(
              children: [
                // The band above the content. The full-page hero is drawn from
                // here at full-screen size and overflows down behind the
                // content (its lower half is plain navy); on a short screen it
                // is lifted so the emblem always ends just above the title.
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, band) {
                      final screen = MediaQuery.sizeOf(context);
                      final scale = math.max(
                        screen.width / _heroSize.width,
                        screen.height / _heroSize.height,
                      );
                      final width = _heroSize.width * scale;
                      final height = _heroSize.height * scale;
                      final top = math.min(
                        0.0,
                        band.maxHeight - 12 - _heroEmblemBottom * height,
                      );
                      return Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Positioned(
                            top: top,
                            left: (screen.width - width) / 2,
                            width: width,
                            height: height,
                            child: const Image(
                              image: AssetImage(AppAssets.bannerOnboarding1),
                              fit: BoxFit.fill,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                // Title + subtitle + sign-in card, on the photo's navy half.
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
                              if (appleSignInSupported) _appleButton(),
                              const SizedBox(height: 24),
                              // One centred line per promise: a Wrap with a
                              // spacer child pushed the first line off-centre.
                              _trustLine(
                                AppLucideIcons.shieldCheck,
                                l10n.authTrustLocalEncryption,
                              ),
                              const SizedBox(height: 6),
                              _trustLine(
                                AppLucideIcons.smartphone,
                                l10n.authTrustOnDevice,
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
            // Status-bar scrim: the photo runs under the status bar and the
            // language button, which sit on its bright sky otherwise.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: MediaQuery.paddingOf(context).top + 64,
              child: const IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x8C000000), Color(0x00000000)],
                    ),
                  ),
                ),
              ),
            ),
            const PositionedDirectional(
              top: 0,
              end: AppSpacing.gutter,
              child: SafeArea(
                child: Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: OnboardingLanguageButton(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _trustLine(IconData icon, String text) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 14, color: Colors.white54),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: AppTypography.micro(Colors.white54),
          ),
        ),
      ],
    );
  }

  Widget _appleButton() {
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: _busy
            ? null
            : () => _signIn(ref.read(authServiceProvider).signInWithApple),
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
}
