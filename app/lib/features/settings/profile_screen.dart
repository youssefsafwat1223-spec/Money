import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/session/app_session.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  static const _methodLabels = {
    'google': 'Google',
    'apple': 'Apple',
    'email': 'البريد',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final session = AppSession.instance;
    final email = session.email ?? '—';
    final method = _methodLabels[session.authMethod] ?? '—';

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.gutter),
      children: [
        const SizedBox(height: AppSpacing.s4),
        Center(
          child: Column(
            children: [
              CircleAvatar(
                radius: 36,
                backgroundColor: c.primary.withValues(alpha: 0.14),
                child: Icon(Icons.person, size: 36, color: c.primary),
              ),
              const SizedBox(height: AppSpacing.s3),
              Text(email, style: AppTypography.headline(c.textMain)),
              Text('الدخول عبر $method',
                  style: AppTypography.caption(c.textLight)),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.s6),
        _tile(context, Icons.settings_outlined, 'الإعدادات',
            () => context.push('/settings')),
        _tile(context, Icons.cloud_outlined, 'النسخ الاحتياطي',
            () => context.push('/backup')),
        _tile(context, Icons.lock_outline, 'الخصوصية والبيانات',
            () => context.push('/privacy')),
        const SizedBox(height: AppSpacing.s5),
        OutlinedButton.icon(
          onPressed: () => AppSession.instance.signOut(),
          icon: const Icon(Icons.logout),
          label: const Text('تسجيل الخروج'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
            side: BorderSide(color: c.border),
          ),
        ),
      ],
    );
  }

  Widget _tile(
      BuildContext context, IconData icon, String title, VoidCallback onTap) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon),
      title: Text(title),
      trailing: const Icon(Icons.chevron_left),
      onTap: onTap,
    );
  }
}
