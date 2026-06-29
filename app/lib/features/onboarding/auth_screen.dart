import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../../core/auth/auth_service.dart';
import '../../core/session/app_session.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/l10n_ext.dart';

import 'widgets/neon_illustration.dart';
import 'widgets/onboarding_scaffold.dart';

TextStyle _alex(double size, FontWeight weight, double height, Color color,
    {bool tabular = false, List<Shadow>? shadows}) {
  return GoogleFonts.inter(
    fontSize: size,
    fontWeight: weight,
    height: height,
    color: color,
    shadows: shadows,
    fontFeatures: tabular ? const [FontFeature.tabularFigures()] : null,
  ).copyWith(
    fontFamilyFallback: [
      GoogleFonts.ibmPlexSansArabic().fontFamily!,
      GoogleFonts.alexandria().fontFamily!,
    ],
  );
}

class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  final _email = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _provider(Future<AuthIdentity> Function() signIn) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final identity = await signIn();
      final wasAuthenticated =
          AppSession.instance.status == SessionStatus.authenticated;
      final returningUser = AppSession.instance.hasCompletedOnboarding;
      await AppSession.instance
          .setIdentity(method: identity.method, email: identity.email);
      if (mounted) {
        if (wasAuthenticated) {
          context.go('/backup');
        } else if (returningUser) {
          context.go('/');
        } else {
          context.push('/onboarding/method-picker');
        }
      }
    } catch (_) {
      if (mounted) {
        _showAuthError();
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _emailContinue() async {
    final email = _email.text.trim();
    if (email.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      await ref.read(authServiceProvider).sendEmailCode(email);
      if (mounted) context.push('/onboarding/otp', extra: email);
    } catch (_) {
      if (mounted) {
        _showAuthError();
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  void _showAuthError() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('تعذر تسجيل الدخول الآن. حاول مرة أخرى بعد لحظات.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final auth = ref.read(authServiceProvider);

    InputBorder bord(Color color, [double w = 1]) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: color, width: w),
        );

    return OnboardingScaffold(
      step: 6,
      onBack: () =>
          context.canPop() ? context.pop() : context.go('/onboarding'),
      title: 'لنبدأ بحسابك',
      subtitle: 'استخدم بريدك الإلكتروني للمتابعة وحفظ بياناتك بشكل آمن.',
      primaryLabel: context.l10n.sendOtpCode,
      onPrimary: _busy ? null : _emailContinue,
      primaryLoading: _busy,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: const NeonIllustration(
              icon: Icons.mark_email_read_rounded,
              size: 170,
            ).animate().fade(duration: 700.ms).scale(curve: Curves.easeOutBack),
          ),
          const SizedBox(height: 32),
          Text('البريد الإلكتروني',
              style: _alex(13, FontWeight.w700, 1.2, c.textMuted)),
          const SizedBox(height: 8),
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            textDirection: TextDirection.ltr,
            style: _alex(15, FontWeight.w600, 1.4, c.textPrimary),
            decoration: InputDecoration(
              hintText: 'you@example.com',
              hintTextDirection: TextDirection.ltr,
              hintStyle: _alex(
                  14, FontWeight.w400, 1.4, c.textMuted.withValues(alpha: 0.7)),
              prefixIcon: Icon(Icons.mail_outline_rounded, color: c.textMuted),
              filled: true,
              fillColor: c.surfaceCard,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              border: bord(c.border),
              enabledBorder: bord(c.border),
              focusedBorder: bord(c.cta, 1.5),
            ),
          ),
          const SizedBox(height: 22),
          Row(
            children: [
              Expanded(child: Divider(color: c.border)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Text('أو تابع عبر',
                    style: _alex(12, FontWeight.w700, 1.2, c.textMuted)),
              ),
              Expanded(child: Divider(color: c.border)),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 52,
            child: SignInWithAppleButton(
              onPressed: _busy ? () {} : () => _provider(auth.signInWithApple),
              text: context.l10n.continueWithApple,
              style: SignInWithAppleButtonStyle.black,
              borderRadius: BorderRadius.circular(16),
            ),
          ),
          const SizedBox(height: 12),
          _providerButton(
            iconWidget: const _GoogleMark(size: 20),
            label: context.l10n.continueWithGoogle,
            background: c.surfaceCard,
            foreground: c.textPrimary,
            border: true,
            onTap: () => _provider(auth.signInWithGoogle),
          ),
        ],
      ),
    );
  }

  Widget _providerButton({
    IconData? icon,
    Widget? iconWidget,
    required String label,
    required Color background,
    required Color foreground,
    required VoidCallback onTap,
    bool border = false,
  }) {
    final c = context.colors;
    return SizedBox(
      height: 50,
      child: OutlinedButton(
        onPressed: _busy ? null : onTap,
        style: OutlinedButton.styleFrom(
          backgroundColor: background,
          side: border
              ? BorderSide(color: c.border.withValues(alpha: 0.2))
              : BorderSide.none,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            iconWidget ?? Icon(icon, color: foreground, size: 22),
            const SizedBox(width: 12),
            Text(
              label,
              style: _alex(14, FontWeight.w800, 1.2, foreground),
            ),
          ],
        ),
      ),
    );
  }
}

class _GoogleMark extends StatelessWidget {
  const _GoogleMark({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    final stroke = size * 0.18;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: Size.square(size),
            painter: _GoogleMarkPainter(strokeWidth: stroke),
          ),
          Positioned(
            right: size * 0.08,
            child: Container(
              width: size * 0.34,
              height: stroke,
              decoration: BoxDecoration(
                color: const Color(0xFF4285F4),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GoogleMarkPainter extends CustomPainter {
  const _GoogleMarkPainter({required this.strokeWidth});

  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final center = rect.center;
    final radius = (size.shortestSide - strokeWidth) / 2;

    void drawArc(Color color, double startAngle, double sweepAngle) {
      final paint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        sweepAngle,
        false,
        paint,
      );
    }

    drawArc(const Color(0xFFEA4335), 2.45, 1.25);
    drawArc(const Color(0xFFFBBC05), 3.75, 1.0);
    drawArc(const Color(0xFF34A853), 4.8, 1.2);
    drawArc(const Color(0xFF4285F4), 6.05, 1.55);
  }

  @override
  bool shouldRepaint(covariant _GoogleMarkPainter oldDelegate) {
    return oldDelegate.strokeWidth != strokeWidth;
  }
}
