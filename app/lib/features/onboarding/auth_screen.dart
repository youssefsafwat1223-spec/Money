import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:go_router/go_router.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../../core/auth/auth_service.dart';
import '../../core/session/app_session.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/utils/l10n_ext.dart';
import '../common/mali_logo.dart';
import '../common/motion.dart';
import 'widgets/premium_ui.dart';

TextStyle _alex(double size, FontWeight weight, double height, Color color, {bool tabular = false, List<Shadow>? shadows}) {
  return GoogleFonts.alexandria(
    fontSize: size,
    fontWeight: weight,
    height: height,
    color: color,
    shadows: shadows,
    fontFeatures: tabular ? const [FontFeature.tabularFigures()] : null,
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
    final identity = await signIn();
    await AppSession.instance
        .setIdentity(method: identity.method, email: identity.email);
    if (mounted) context.push('/onboarding/method');
  }

  Future<void> _emailContinue() async {
    final email = _email.text.trim();
    if (email.isEmpty || _busy) return;
    setState(() => _busy = true);
    await ref.read(authServiceProvider).sendEmailCode(email);
    setState(() => _busy = false);
    if (mounted) context.push('/onboarding/otp', extra: email);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final auth = ref.read(authServiceProvider);
    final actionForeground = maliPrimaryActionForeground(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return PremiumBackground(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter, vertical: 8.0),
            child: Row(
              children: [
                Container(
                  decoration: BoxDecoration(
                    color: c.surface.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: IconButton(
                    onPressed: () {
                      if (context.canPop()) {
                        context.pop();
                      } else {
                        context.go('/onboarding');
                      }
                    },
                    icon: Icon(Icons.arrow_forward_rounded, color: c.textMain, size: 20),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 8),
                  const Center(child: MaliLogo(size: 64, glow: false)),
                  const SizedBox(height: 20),
                  Text(
                    context.l10n.signInToStart, 
                    textAlign: TextAlign.center, 
                    style: _alex(24, FontWeight.w800, 1.2, c.textMain),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    context.l10n.signInSubtitle,
                    textAlign: TextAlign.center,
                    style: _alex(13, FontWeight.w500, 1.5, c.textLight),
                  ),
                  const SizedBox(height: 24),
                  
                  PremiumMotion(
                    delay: const Duration(milliseconds: 100),
                    child: GlassCard(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Center(
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                              decoration: BoxDecoration(
                                color: c.accent.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(color: c.accent.withValues(alpha: 0.22)),
                              ),
                              child: Text(
                                context.l10n.noPassword,
                                style: _alex(12, FontWeight.w800, 1.2, c.accent),
                              ),
                            ),
                          ),
                          const SizedBox(height: 24),
                          
                          SizedBox(
                            height: 50,
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
                            background: c.surface,
                            foreground: c.textMain,
                            border: true,
                            onTap: () => _provider(auth.signInWithGoogle),
                          ),
                          const SizedBox(height: 20),
                          Row(
                            children: [
                              Expanded(child: Divider(color: c.border.withValues(alpha: 0.3))),
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 16),
                                child: Text(context.l10n.or, style: _alex(12, FontWeight.w600, 1.2, c.textLight)),
                              ),
                              Expanded(child: Divider(color: c.border.withValues(alpha: 0.3))),
                            ],
                          ),
                          const SizedBox(height: 20),
                          Text(
                            context.l10n.continueWithEmail,
                            style: _alex(12, FontWeight.w700, 1.2, c.textLight),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _email,
                            keyboardType: TextInputType.emailAddress,
                            style: _alex(15, FontWeight.w600, 1.4, c.textMain),
                            textDirection: TextDirection.ltr,
                            decoration: InputDecoration(
                              hintText: context.l10n.email,
                              hintTextDirection: TextDirection.rtl,
                              hintStyle: _alex(14, FontWeight.w400, 1.4, c.textLight.withValues(alpha: 0.4)),
                              prefixIcon: Icon(Icons.mail_outline_rounded, color: c.textLight),
                              filled: true,
                              fillColor: c.surface.withValues(alpha: isDark ? 0.06 : 0.45),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.s4,
                                vertical: 16,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(16),
                                borderSide: BorderSide(color: Colors.white.withValues(alpha: isDark ? 0.08 : 0.4)),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(16),
                                borderSide: BorderSide(color: Colors.white.withValues(alpha: isDark ? 0.08 : 0.4)),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(16),
                                borderSide: BorderSide(color: isDark ? c.accent : c.primary, width: 1.5),
                              ),
                            ),
                          ),
                          const SizedBox(height: 20),
                          SizedBox(
                            height: 52,
                            width: double.infinity,
                            child: Container(
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
                                onPressed: _busy ? null : _emailContinue,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.transparent,
                                  shadowColor: Colors.transparent,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                ),
                                child: Text(
                                  context.l10n.sendOtpCode,
                                  style: _alex(15, FontWeight.w800, 1.2, actionForeground),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  
                  const SizedBox(height: 32),
                  Center(
                    child: Text(
                      context.l10n.byContinuingAgree,
                      textAlign: TextAlign.center,
                      style: _alex(11, FontWeight.w500, 1.5, c.textLight),
                    ),
                  ),
                  const SizedBox(height: 32),
                ],
              ),
            ),
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
          side: border ? BorderSide(color: c.border.withValues(alpha: 0.2)) : BorderSide.none,
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
