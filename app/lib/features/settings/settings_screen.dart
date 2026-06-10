import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/di/app_providers.dart';
import '../../core/session/app_session.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/theme_mode_provider.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../domain/entities/engagement_entities.dart';
import '../common/section_hero_header.dart';
import 'settings_providers.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefsAsync = ref.watch(notificationPreferencesProvider);
    final settingsAsync = ref.watch(userSettingsProvider);
    final c = context.colors;

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        0,
        0,
        0,
        120,
      ),
      children: [
        const SectionHeroHeader(
          title: 'الإعدادات',
          subtitle: 'تحكم في الخصوصية، الإشعارات، شكل التطبيق، وقواعد الالتقاط.',
          metrics: [
            SectionHeroMetric(value: 'محلي', label: 'المعالجة'),
            SectionHeroMetric(value: 'E2E', label: 'النسخ'),
            SectionHeroMetric(value: 'RTL', label: 'العربية'),
          ],
        ),
        const SizedBox(height: AppSpacing.s5),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
          child: Column(
            children: [
        _Section(
          title: 'الحساب',
          children: [
            _AccountTile(email: AppSession.instance.email ?? 'غير مسجل'),
            _NavTile(
              icon: AppLucideIcons.user,
              title: 'رقم الهاتف',
              subtitle: 'غير مضاف',
              onTap: () => _showSoon(context, 'رقم الهاتف'),
            ),
            _NavTile(
              icon: AppLucideIcons.walletCards,
              title: 'الحسابات',
              subtitle: 'إدارة أرصدة البنوك والبطاقات',
              onTap: () => _showSoon(context, 'الحسابات'),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.s5),
        _Section(
          title: 'القواعد والتفضيلات',
          children: [
            settingsAsync.maybeWhen(
              data: (settings) => _ThemeTile(
                value: themeModeFromKey(settings.theme),
                onChanged: (mode) => _saveTheme(ref, mode),
              ),
              orElse: () => const ListTile(title: Text('الثيم')),
            ),
            _NavTile(
              icon: AppLucideIcons.inbox,
              title: 'التصنيفات',
              subtitle: 'إدارة تصنيفات الصرف والدخل',
              onTap: () => _showSoon(context, 'التصنيفات'),
            ),
            _NavTile(
              icon: AppLucideIcons.arrowLeftRight,
              title: 'قواعد المتاجر',
              subtitle: 'تعلّم تصنيف المتاجر تلقائياً',
              onTap: () => _showSoon(context, 'قواعد المتاجر'),
            ),
            _NavTile(
              icon: AppLucideIcons.alertTriangle,
              title: 'البطاقات المتجاهلة',
              subtitle: 'تجاهل SMS من بطاقات محددة',
              onTap: () => _showSoon(context, 'البطاقات المتجاهلة'),
            ),
            _NavTile(
              icon: AppLucideIcons.flame,
              title: 'Apple Pay ورسائل البنك',
              subtitle: 'تحسين الالتقاط من مصادر الدفع',
              onTap: () => _showSoon(context, 'Apple Pay ورسائل البنك'),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.s5),
        prefsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Text('حدث خطأ: $error'),
          data: (prefs) => _Section(
            title: 'الإشعارات',
            children: [
              _SwitchTile(
                title: 'تنبيهات تأكيد العمليات',
                value: prefs.captureReview,
                onChanged: (value) =>
                    _savePrefs(ref, prefs.copyWith(captureReview: value)),
              ),
              _SwitchTile(
                title: 'الإشعارات الخفيفة',
                value: prefs.captureLight,
                onChanged: (value) =>
                    _savePrefs(ref, prefs.copyWith(captureLight: value)),
              ),
              _SwitchTile(
                title: 'تنبيه 80% من الميزانية',
                value: prefs.budgetWarning,
                onChanged: (value) =>
                    _savePrefs(ref, prefs.copyWith(budgetWarning: value)),
              ),
              _SwitchTile(
                title: 'تنبيه تجاوز الميزانية',
                value: prefs.budgetOver,
                onChanged: (value) =>
                    _savePrefs(ref, prefs.copyWith(budgetOver: value)),
              ),
              _SwitchTile(
                title: 'تنبيهات الإنجازات',
                value: prefs.achievements,
                onChanged: (value) =>
                    _savePrefs(ref, prefs.copyWith(achievements: value)),
              ),
              _SwitchTile(
                title: 'تذكير السلسلة',
                value: prefs.streakReminder,
                onChanged: (value) =>
                    _savePrefs(ref, prefs.copyWith(streakReminder: value)),
              ),
              _NavTile(
                icon: AppLucideIcons.moon,
                title: 'ساعات الهدوء',
                subtitle:
                    '${prefs.quietHoursStartHour}:00 - ${prefs.quietHoursEndHour}:00',
                onTap: () => _showSoon(context, 'ساعات الهدوء'),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.s5),
        _Section(
          title: 'المكافآت والبيانات',
          children: [
            _NavTile(
              icon: AppLucideIcons.gift,
              title: 'دعوة الأصدقاء',
              subtitle: 'شارك التطبيق لاحقاً',
              trailing: const _SoonBadge(),
              onTap: () => _showSoon(context, 'دعوة الأصدقاء'),
            ),
            _NavTile(
              icon: AppLucideIcons.inbox,
              title: 'تصدير البيانات',
              subtitle: 'CSV محلي لاحقاً',
              onTap: () => _showSoon(context, 'تصدير البيانات'),
            ),
            _NavTile(
              icon: AppLucideIcons.inbox,
              title: 'استيراد العمليات',
              subtitle: 'من تطبيق آخر',
              trailing: const _SoonBadge(),
              onTap: () => _showSoon(context, 'استيراد العمليات'),
            ),
            _NavTile(
              icon: AppLucideIcons.repeat,
              title: 'ابدأ من جديد',
              subtitle: 'مسح البيانات مع إبقاء الحساب',
              onTap: () => context.push('/privacy'),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.s5),
        _Section(
          title: 'أتمتة إضافية',
          children: [
            _NavTile(
              icon: AppLucideIcons.user,
              title: 'Double Tap للإضافة',
              subtitle: 'اختصار سريع للإضافة لاحقاً',
              trailing: const _SoonBadge(),
              onTap: () => _showSoon(context, 'Double Tap للإضافة'),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.s5),
        _Section(
          title: 'الدعم',
          children: [
            _NavTile(
              icon: AppLucideIcons.heartPulse,
              title: 'الخصوصية والبيانات',
              onTap: () => context.push('/privacy'),
            ),
            _NavTile(
              icon: AppLucideIcons.alertTriangle,
              title: 'عن التطبيق',
              subtitle: 'Money Companion MVP',
              onTap: () => _showSoon(context, 'عن التطبيق'),
            ),
            _NavTile(
              icon: AppLucideIcons.receipt,
              title: 'تواصل معنا',
              onTap: () => _showSoon(context, 'تواصل معنا'),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.s5),
        _StandaloneTile(
          icon: AppLucideIcons.inbox,
          title: 'النسخ الاحتياطي المشفر',
          onTap: () => context.push('/backup'),
        ),
        const SizedBox(height: AppSpacing.s3),
        _StandaloneTile(
          icon: AppLucideIcons.arrowLeftRight,
          title: 'تسجيل الخروج',
          onTap: () => AppSession.instance.signOut(),
        ),
        const SizedBox(height: AppSpacing.s4),
        Center(
          child: TextButton(
            onPressed: () => _showSoon(context, 'حذف الحساب'),
            child: Text('حذف الحساب', style: AppTypography.body(c.danger)),
          ),
        ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _savePrefs(
    WidgetRef ref,
    NotificationPreferences preferences,
  ) async {
    await ref.read(saveNotificationPreferencesUseCaseProvider).call(preferences);
    refreshNotificationPreferences(ref);
  }

  Future<void> _saveTheme(WidgetRef ref, ThemeMode mode) async {
    ref.read(themeModeOverrideProvider.notifier).state = mode;
    await ref.read(saveThemeModeUseCaseProvider).call(themeModeToKey(mode));
    refreshUserSettings(ref);
    ref.invalidate(persistedThemeModeProvider);
  }

  void _showSoon(BuildContext context, String title) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter,
          AppSpacing.s3,
          AppSpacing.gutter,
          AppSpacing.s6,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: AppTypography.title2(context.colors.textMain)),
            const SizedBox(height: AppSpacing.s2),
            Text(
              'الميزة دي متجهزة كمكان في الإعدادات، وهنوصلها بالمنطق الكامل في دفعة قريبة.',
              style: AppTypography.callout(context.colors.textLight),
            ),
            const SizedBox(height: AppSpacing.s4),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('تمام'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s3),
          child: Text(title, style: AppTypography.caption(c.textLight)),
        ),
        const SizedBox(height: AppSpacing.s2),
        Container(
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(color: c.border),
          ),
          child: Column(children: children),
        ),
      ],
    );
  }
}

class _AccountTile extends StatelessWidget {
  const _AccountTile({required this.email});

  final String email;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ListTile(
      leading: _TileIcon(icon: AppLucideIcons.user, color: c.primary),
      title: Text('Youssef Safwat', style: AppTypography.bodyStrong(c.textMain)),
      subtitle: Text(email),
      trailing: const _PlanBadge(),
    );
  }
}

class _ThemeTile extends StatelessWidget {
  const _ThemeTile({required this.value, required this.onChanged});

  final ThemeMode value;
  final ValueChanged<ThemeMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.s3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _TileIcon(icon: AppLucideIcons.sun, color: c.accent),
              const SizedBox(width: AppSpacing.s3),
              Text('المظهر', style: AppTypography.bodyStrong(c.textMain)),
            ],
          ),
          const SizedBox(height: AppSpacing.s3),
          SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(value: ThemeMode.system, label: Text('تلقائي')),
              ButtonSegment(value: ThemeMode.light, label: Text('فاتح')),
              ButtonSegment(value: ThemeMode.dark, label: Text('داكن')),
            ],
            selected: {value},
            onSelectionChanged: (selected) => onChanged(selected.first),
          ),
        ],
      ),
    );
  }
}

class _NavTile extends StatelessWidget {
  const _NavTile({
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ListTile(
      leading: _TileIcon(icon: icon, color: c.primary),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: trailing ?? const Icon(AppLucideIcons.arrowLeftRight),
      onTap: onTap,
    );
  }
}

class _SwitchTile extends StatelessWidget {
  const _SwitchTile({
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

class _StandaloneTile extends StatelessWidget {
  const _StandaloneTile({
    required this.icon,
    required this.title,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: c.border),
      ),
      child: ListTile(
        leading: _TileIcon(icon: icon, color: c.textLight),
        title: Text(title),
        trailing: const Icon(AppLucideIcons.arrowLeftRight),
        onTap: onTap,
      ),
    );
  }
}

class _TileIcon extends StatelessWidget {
  const _TileIcon({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Icon(icon, color: color, size: 21),
    );
  }
}

class _PlanBadge extends StatelessWidget {
  const _PlanBadge();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text('Free', style: AppTypography.caption(c.textLight)),
    );
  }
}

class _SoonBadge extends StatelessWidget {
  const _SoonBadge();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: c.success.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text('قريباً', style: AppTypography.caption(c.success)),
    );
  }
}
