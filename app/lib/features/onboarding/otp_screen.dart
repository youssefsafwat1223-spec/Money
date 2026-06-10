import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_service.dart';
import '../../core/session/app_session.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';

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
        _error = 'الرمز غير صحيح';
      });
      return;
    }
    await AppSession.instance
        .completeOnboarding(method: identity.method, email: identity.email);
    if (mounted) context.go('/');
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      appBar: AppBar(),
      body: Padding(
        padding: const EdgeInsets.all(AppSpacing.gutter),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: AppSpacing.s4),
            Text('أدخل رمز التحقق', style: AppTypography.title2(c.textMain)),
            const SizedBox(height: AppSpacing.s2),
            Text('أرسلنا كوداً إلى ${widget.email}',
                style: AppTypography.body(c.textLight)),
            const SizedBox(height: AppSpacing.s6),
            TextField(
              controller: _code,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              maxLength: 6,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: AppTypography.title1(c.textMain),
              decoration: InputDecoration(
                counterText: '',
                hintText: '••••••',
                errorText: _error,
                filled: true,
                fillColor: c.surface2,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  borderSide: BorderSide(color: c.border),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.s5),
            SizedBox(
              height: 56,
              child: FilledButton(
                onPressed: _busy ? null : _verify,
                style: FilledButton.styleFrom(
                  backgroundColor: c.primary,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md)),
                ),
                child: Text('تأكيد',
                    style: AppTypography.bodyStrong(Colors.white)),
              ),
            ),
            const SizedBox(height: AppSpacing.s4),
            Center(
              child: Text('للتجربة: الرمز 123456',
                  style: AppTypography.caption(c.textLight)),
            ),
          ],
        ),
      ),
    );
  }
}
