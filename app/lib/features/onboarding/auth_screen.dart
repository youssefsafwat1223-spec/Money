import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_service.dart';
import '../../core/session/app_session.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../common/mali_logo.dart';

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

    return Scaffold(
      appBar: AppBar(),
      body: Padding(
        padding: const EdgeInsets.all(AppSpacing.gutter),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Spacer(),
            const Center(child: MaliLogo(size: 84)),
            const SizedBox(height: AppSpacing.s4),
            Text('سجّل دخولك للبدء',
                textAlign: TextAlign.center,
                style: AppTypography.title1(c.textMain)),
            const SizedBox(height: AppSpacing.s2),
            Text('الدخول لتحديد هويتك فقط. بياناتك المالية تبقى على جهازك.',
                textAlign: TextAlign.center,
                style: AppTypography.body(c.textLight)),
            const Spacer(),
            _providerButton(
              icon: Icons.apple,
              label: 'المتابعة مع Apple',
              background: Colors.black,
              foreground: Colors.white,
              onTap: () => _provider(auth.signInWithApple),
            ),
            const SizedBox(height: AppSpacing.s3),
            _providerButton(
              icon: Icons.account_circle_outlined,
              label: 'المتابعة مع Google',
              background: c.surface2,
              foreground: c.textMain,
              border: true,
              onTap: () => _provider(auth.signInWithGoogle),
            ),
            const SizedBox(height: AppSpacing.s4),
            Row(children: [
              Expanded(child: Divider(color: c.border)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s3),
                child: Text('أو', style: AppTypography.caption(c.textLight)),
              ),
              Expanded(child: Divider(color: c.border)),
            ]),
            const SizedBox(height: AppSpacing.s4),
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              style: AppTypography.body(c.textMain),
              decoration: InputDecoration(
                hintText: 'البريد الإلكتروني',
                filled: true,
                fillColor: c.surface2,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  borderSide: BorderSide(color: c.border),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.s3),
            SizedBox(
              height: 56,
              child: FilledButton(
                onPressed: _busy ? null : _emailContinue,
                style: FilledButton.styleFrom(
                  backgroundColor: c.primary,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md)),
                ),
                child: Text('إرسال رمز الدخول',
                    style: AppTypography.bodyStrong(Colors.white)),
              ),
            ),
            const SizedBox(height: AppSpacing.s4),
            Text('بالمتابعة توافق على الشروط وسياسة الخصوصية',
                textAlign: TextAlign.center,
                style: AppTypography.caption(c.textLight)),
            const SizedBox(height: AppSpacing.s4),
          ],
        ),
      ),
    );
  }

  Widget _providerButton({
    required IconData icon,
    required String label,
    required Color background,
    required Color foreground,
    required VoidCallback onTap,
    bool border = false,
  }) {
    final c = context.colors;
    return SizedBox(
      height: 56,
      child: FilledButton.icon(
        onPressed: _busy ? null : onTap,
        icon: Icon(icon, color: foreground),
        label: Text(label, style: AppTypography.bodyStrong(foreground)),
        style: FilledButton.styleFrom(
          backgroundColor: background,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
            side: border ? BorderSide(color: c.border) : BorderSide.none,
          ),
        ),
      ),
    );
  }
}
