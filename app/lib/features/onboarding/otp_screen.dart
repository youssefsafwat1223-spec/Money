import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/auth/auth_service.dart';
import '../../core/utils/l10n_ext.dart';
import '../../core/session/app_session.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../common/motion.dart';
import 'widgets/premium_ui.dart';

TextStyle _alex(double size, FontWeight weight, double height, Color color, {bool tabular = false}) {
  return GoogleFonts.inter(
    fontSize: size,
    fontWeight: weight,
    height: height,
    color: color,
    fontFeatures: tabular ? const [FontFeature.tabularFigures()] : null,
  ).copyWith(
    fontFamilyFallback: [
      GoogleFonts.ibmPlexSansArabic().fontFamily!,
      GoogleFonts.alexandria().fontFamily!,
    ],
  );
}

class OtpScreen extends ConsumerStatefulWidget {
  const OtpScreen({super.key, required this.email});

  final String email;

  @override
  ConsumerState<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends ConsumerState<OtpScreen> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    final code = _code.text.trim();
    if (code.length < 6 || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final identity = await ref
        .read(authServiceProvider)
        .verifyEmailCode(email: widget.email, code: code);
    if (identity == null) {
      setState(() {
        _busy = false;
        _error = context.l10n.invalidOtpCode;
      });
      return;
    }
    final wasAuthenticated =
        AppSession.instance.status == SessionStatus.authenticated;
    await AppSession.instance
        .setIdentity(method: identity.method, email: identity.email);
    if (mounted) {
      wasAuthenticated ? context.go('/backup') : context.push('/onboarding/method');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
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
                    onPressed: () => context.pop(),
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
                  const SizedBox(height: 16),
                  Center(
                    child: GlowingIcon(
                      icon: Icons.mark_email_read_rounded,
                      color: c.primary,
                      size: 40,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    context.l10n.enterOtpCode,
                    textAlign: TextAlign.center,
                    style: _alex(24, FontWeight.w800, 1.3, c.textMain),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    context.l10n.otpSentTo,
                    textAlign: TextAlign.center,
                    style: _alex(14, FontWeight.w500, 1.5, c.textLight),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    widget.email,
                    style: _alex(14, FontWeight.w800, 1.5, c.primary),
                    textDirection: TextDirection.ltr,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 28),
                  
                  PremiumMotion(
                    delay: const Duration(milliseconds: 100),
                    child: GlassCard(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          TextField(
                            controller: _code,
                            keyboardType: TextInputType.number,
                            textAlign: TextAlign.center,
                            maxLength: 6,
                            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                            style: _alex(32, FontWeight.w800, 1.2, c.textMain, tabular: true),
                            decoration: InputDecoration(
                              counterText: '',
                              hintText: '••••••',
                              hintStyle: _alex(32, FontWeight.w400, 1.2, c.textLight.withValues(alpha: 0.25), tabular: true),
                              errorText: _error,
                              errorStyle: _alex(13, FontWeight.w600, 1.2, c.danger),
                              filled: true,
                              fillColor: c.surface.withValues(alpha: isDark ? 0.06 : 0.45),
                              contentPadding: const EdgeInsets.symmetric(
                                vertical: 20,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(20),
                                borderSide: BorderSide(color: Colors.white.withValues(alpha: isDark ? 0.08 : 0.4)),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(20),
                                borderSide: BorderSide(color: Colors.white.withValues(alpha: isDark ? 0.08 : 0.4)),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(20),
                                borderSide: BorderSide(color: isDark ? c.accent : c.primary, width: 1.5),
                              ),
                              errorBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(20),
                                borderSide: BorderSide(color: c.danger, width: 1.5),
                              ),
                              focusedErrorBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(20),
                                borderSide: BorderSide(color: c.danger, width: 2),
                              ),
                            ),
                          ),
                          const SizedBox(height: 20),
                          SizedBox(
                            height: 52,
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
                                onPressed: _busy ? null : _verify,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.transparent,
                                  shadowColor: Colors.transparent,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                ),
                                child: _busy
                                    ? Center(
                                        child: SizedBox(
                                          width: 24,
                                          height: 24,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2.5,
                                            color: actionForeground,
                                          ),
                                        ),
                                      )
                                    : Text(
                                        context.l10n.verifyCode,
                                        style: _alex(15, FontWeight.w800, 1.2, actionForeground),
                                      ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  
                  const SizedBox(height: 40),
                  Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: c.surface.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(99),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                      ),
                      child: Text(
                        context.l10n.demoOtpCode,
                        style: _alex(12, FontWeight.w700, 1.2, c.textLight),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
