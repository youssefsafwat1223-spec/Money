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
import 'widgets/neon_illustration.dart';
import 'widgets/onboarding_scaffold.dart';

TextStyle _alex(double size, FontWeight weight, double height, Color color,
    {bool tabular = false}) {
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
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    InputBorder bord(Color color, [double w = 1]) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: color, width: w),
        );

    return OnboardingScaffold(
      step: 7,
      onBack: () => context.pop(),
      title: context.l10n.enterOtpCode,
      subtitle: 'أرسلنا رمز تحقق من 6 أرقام إلى بريدك.',
      primaryLabel: context.l10n.verifyCode,
      onPrimary: _busy ? null : _verify,
      primaryLoading: _busy,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Center(
            child: NeonIllustration(
              icon: Icons.mark_email_read_rounded,
              size: 150,
            ),
          ),
          const SizedBox(height: 22),
          Center(
            child: Text(
              widget.email,
              textDirection: TextDirection.ltr,
              style: _alex(14, FontWeight.w800, 1.4, c.cta),
            ),
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _code,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            maxLength: 6,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: _alex(28, FontWeight.w800, 1.2, c.textPrimary, tabular: true)
                .copyWith(letterSpacing: 10),
            decoration: InputDecoration(
              counterText: '',
              hintText: '••••••',
              hintStyle: _alex(28, FontWeight.w400, 1.2,
                      c.textMuted.withValues(alpha: 0.3),
                      tabular: true)
                  .copyWith(letterSpacing: 10),
              errorText: _error,
              errorStyle: _alex(13, FontWeight.w600, 1.2, c.danger),
              filled: true,
              fillColor: c.surfaceCard,
              contentPadding: const EdgeInsets.symmetric(vertical: 18),
              border: bord(c.border),
              enabledBorder: bord(c.border),
              focusedBorder: bord(c.cta, 1.5),
              errorBorder: bord(c.danger),
              focusedErrorBorder: bord(c.danger, 1.5),
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: Text(
              context.l10n.demoOtpCode,
              style: _alex(12, FontWeight.w600, 1.4, c.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}
