import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/di/app_providers.dart';
import '../../core/session/app_session.dart';
import '../../core/theme/app_spacing.dart';
import '../../domain/entities/engagement_entities.dart';
import 'settings_providers.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(notificationPreferencesProvider);
    return async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('حدث خطأ: $error')),
        data: (prefs) {
          return ListView(
            padding: const EdgeInsets.all(AppSpacing.gutter),
            children: [
              _ToggleTile(
                title: 'تنبيهات العمليات الجديدة',
                value: prefs.captureReview,
                onChanged: (value) => _save(
                  ref,
                  prefs.copyWith(captureReview: value),
                ),
              ),
              _ToggleTile(
                title: 'الإشعارات الخفيفة',
                value: prefs.captureLight,
                onChanged: (value) => _save(
                  ref,
                  prefs.copyWith(captureLight: value),
                ),
              ),
              _ToggleTile(
                title: 'تنبيه 80% من الميزانية',
                value: prefs.budgetWarning,
                onChanged: (value) => _save(
                  ref,
                  prefs.copyWith(budgetWarning: value),
                ),
              ),
              _ToggleTile(
                title: 'تنبيه تجاوز الميزانية',
                value: prefs.budgetOver,
                onChanged: (value) => _save(
                  ref,
                  prefs.copyWith(budgetOver: value),
                ),
              ),
              _ToggleTile(
                title: 'تنبيهات الإنجازات',
                value: prefs.achievements,
                onChanged: (value) => _save(
                  ref,
                  prefs.copyWith(achievements: value),
                ),
              ),
              _ToggleTile(
                title: 'تذكير السلسلة',
                value: prefs.streakReminder,
                onChanged: (value) => _save(
                  ref,
                  prefs.copyWith(streakReminder: value),
                ),
              ),
              const SizedBox(height: AppSpacing.s5),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('ساعات الهدوء'),
                subtitle: Text(
                  '${prefs.quietHoursStartHour}:00 - ${prefs.quietHoursEndHour}:00',
                ),
              ),
              const Divider(height: AppSpacing.s6),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.bar_chart_outlined),
                title: const Text('التقارير'),
                trailing: const Icon(Icons.chevron_left),
                onTap: () => context.push('/reports'),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.repeat),
                title: const Text('الاشتراكات'),
                trailing: const Icon(Icons.chevron_left),
                onTap: () => context.push('/subscriptions'),
              ),
              const Divider(height: AppSpacing.s6),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.person_outline),
                title: const Text('الحساب'),
                subtitle: Text(AppSession.instance.email ?? '—'),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.cloud_outlined),
                title: const Text('النسخ الاحتياطي'),
                trailing: const Icon(Icons.chevron_left),
                onTap: () => context.push('/backup'),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.lock_outline),
                title: const Text('الخصوصية والبيانات'),
                trailing: const Icon(Icons.chevron_left),
                onTap: () => context.push('/privacy'),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.logout),
                title: const Text('تسجيل الخروج'),
                onTap: () => AppSession.instance.signOut(),
              ),
            ],
          );
        },
      );
  }

  Future<void> _save(WidgetRef ref, NotificationPreferences preferences) async {
    await ref.read(saveNotificationPreferencesUseCaseProvider).call(preferences);
    refreshNotificationPreferences(ref);
  }
}

class _ToggleTile extends StatelessWidget {
  const _ToggleTile({
    required this.title,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      value: value,
      onChanged: onChanged,
      title: Text(title),
    );
  }
}
