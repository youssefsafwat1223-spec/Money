import 'dart:ui';
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
import '../../domain/entities/supporting_entities.dart';
import '../common/category_catalog.dart';
import '../common/motion.dart';
import 'settings_providers.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  static const _methodLabels = {
    'google': 'Google',
    'apple': 'Apple',
    'email': 'البريد الإلكتروني',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefsAsync = ref.watch(notificationPreferencesProvider);
    final settingsAsync = ref.watch(userSettingsProvider);
    final c = context.colors;
    final session = AppSession.instance;
    final email = session.email ?? '—';
    final method = _methodLabels[session.authMethod] ?? '—';

    return Scaffold(
      body: ListView(
        padding: const EdgeInsets.fromLTRB(0, 0, 0, 120),
        children: [
          _SettingsHeader(email: email, method: method),
          const SizedBox(height: AppSpacing.s5),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
            child: Column(
              children: [
                PremiumMotion(
                  delay: const Duration(milliseconds: 50),
                  child: _Section(
                    title: 'الملف الشخصي والتحليل',
                    children: [
                      _NavTile(
                        icon: Icons.bar_chart_outlined,
                        title: 'الرؤى والتقارير',
                        subtitle: 'اقرأ صرفك كاتجاهات يومية وتصنيفات ومتاجر',
                        onTap: () => context.push('/reports'),
                      ),
                      _NavTile(
                        icon: Icons.emoji_events_outlined,
                        title: 'الإنجازات والمستوى',
                        subtitle: 'شارات ومستويات تشجعك تكمل عادة المتابعة',
                        onTap: () => context.push('/achievements'),
                      ),
                      _NavTile(
                        icon: Icons.receipt_long_outlined,
                        title: 'الاشتراكات والفواتير',
                        subtitle: 'تتبع اشتراكاتك وأقساطك والتزاماتك الدورية',
                        onTap: () => context.push('/subscriptions'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.s5),
                settingsAsync.maybeWhen(
                  data: (settings) => PremiumMotion(
                    delay: const Duration(milliseconds: 75),
                    child: _Section(
                      title: 'التفضيلات العامة',
                      children: [
                        _NavTile(
                          icon: Icons.language_outlined,
                          title: 'اللغة',
                          subtitle: _languageLabel(settings.language),
                          onTap: () => _showSettingsPicker(
                            context,
                            ref,
                            title: 'اللغة',
                            current: settings.language,
                            values: const {'ar': 'العربية', 'en': 'English'},
                            apply: (value) =>
                                settings.copyWith(language: value),
                          ),
                        ),
                        _NavTile(
                          icon: Icons.flag_outlined,
                          title: 'الدولة',
                          subtitle: _countryLabel(settings.country),
                          onTap: () => _showSettingsPicker(
                            context,
                            ref,
                            title: 'الدولة',
                            current: settings.country,
                            values: const {
                              'SA': 'السعودية',
                              'AE': 'الإمارات',
                              'EG': 'مصر',
                              'KW': 'الكويت',
                              'QA': 'قطر',
                              'BH': 'البحرين',
                              'OM': 'عمان',
                            },
                            apply: (value) => settings.copyWith(country: value),
                          ),
                        ),
                        _NavTile(
                          icon: Icons.payments_outlined,
                          title: 'العملة الأساسية',
                          subtitle: settings.currency,
                          onTap: () => _showSettingsPicker(
                            context,
                            ref,
                            title: 'العملة الأساسية',
                            current: settings.currency,
                            values: const {
                              'SAR': 'SAR - ريال سعودي',
                              'AED': 'AED - درهم إماراتي',
                              'EGP': 'EGP - جنيه مصري',
                              'KWD': 'KWD - دينار كويتي',
                              'QAR': 'QAR - ريال قطري',
                              'USD': 'USD - دولار',
                            },
                            apply: (value) =>
                                settings.copyWith(currency: value),
                          ),
                        ),
                      ],
                    ),
                  ),
                  orElse: () => const SizedBox.shrink(),
                ),
                const SizedBox(height: AppSpacing.s5),
                PremiumMotion(
                  delay: const Duration(milliseconds: 100),
                  child: _Section(
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
                        subtitle: 'مصروفات ودخل وتحويلات في مجموعات واضحة',
                        onTap: () => _showCategoriesSheet(context, ref),
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
                        onTap: () =>
                            _showSoon(context, 'Apple Pay ورسائل البنك'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.s5),
                prefsAsync.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (error, _) => Text('حدث خطأ: $error'),
                  data: (prefs) => PremiumMotion(
                    delay: const Duration(milliseconds: 150),
                    child: _Section(
                      title: 'الإشعارات والتنبيهات',
                      children: [
                        _SwitchTile(
                          title: 'تنبيهات تأكيد العمليات',
                          icon: Icons.rate_review_outlined,
                          iconColor: c.primary,
                          value: prefs.captureReview,
                          onChanged: (value) => _savePrefs(
                              ref, prefs.copyWith(captureReview: value)),
                        ),
                        _SwitchTile(
                          title: 'الإشعارات الخفيفة',
                          icon: Icons.notifications_paused_outlined,
                          iconColor: c.accent,
                          value: prefs.captureLight,
                          onChanged: (value) => _savePrefs(
                              ref, prefs.copyWith(captureLight: value)),
                        ),
                        _SwitchTile(
                          title: 'تنبيه 80% من الميزانية',
                          icon: Icons.warning_amber_rounded,
                          iconColor: c.accent,
                          value: prefs.budgetWarning,
                          onChanged: (value) => _savePrefs(
                              ref, prefs.copyWith(budgetWarning: value)),
                        ),
                        _SwitchTile(
                          title: 'تنبيه تجاوز الميزانية',
                          icon: Icons.error_outline_rounded,
                          iconColor: c.danger,
                          value: prefs.budgetOver,
                          onChanged: (value) => _savePrefs(
                              ref, prefs.copyWith(budgetOver: value)),
                        ),
                        _SwitchTile(
                          title: 'تنبيهات الإنجازات',
                          icon: Icons.emoji_events_outlined,
                          iconColor: c.success,
                          value: prefs.achievements,
                          onChanged: (value) => _savePrefs(
                              ref, prefs.copyWith(achievements: value)),
                        ),
                        _SwitchTile(
                          title: 'تذكير السلسلة',
                          icon: Icons.local_fire_department_outlined,
                          iconColor: c.accent,
                          value: prefs.streakReminder,
                          onChanged: (value) => _savePrefs(
                              ref, prefs.copyWith(streakReminder: value)),
                        ),
                        _SwitchTile(
                          title: 'التقرير الأسبوعي',
                          icon: Icons.insights_outlined,
                          iconColor: c.primary,
                          value: prefs.weeklyReport,
                          onChanged: (value) => _savePrefs(
                              ref, prefs.copyWith(weeklyReport: value)),
                        ),
                        _SwitchTile(
                          title: 'تذكير الاشتراكات والفواتير',
                          icon: Icons.event_available_outlined,
                          iconColor: c.accent,
                          value: prefs.subscriptionReminder,
                          onChanged: (value) => _savePrefs(
                            ref,
                            prefs.copyWith(subscriptionReminder: value),
                          ),
                        ),
                        _SwitchTile(
                          title: 'احتفالات الأهداف',
                          icon: Icons.flag_outlined,
                          iconColor: c.success,
                          value: prefs.goalMilestone,
                          onChanged: (value) => _savePrefs(
                              ref, prefs.copyWith(goalMilestone: value)),
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
                ),
                const SizedBox(height: AppSpacing.s5),
                PremiumMotion(
                  delay: const Duration(milliseconds: 200),
                  child: _Section(
                    title: 'النسخ الاحتياطي والأمان',
                    children: [
                      _NavTile(
                        icon: AppLucideIcons.inbox,
                        title: 'النسخ الاحتياطي المشفر',
                        subtitle:
                            'نسخ مشفّر E2E لا نقدر نقرأه واستعادته بأي وقت',
                        onTap: () => context.push('/backup'),
                      ),
                      _NavTile(
                        icon: AppLucideIcons.heartPulse,
                        title: 'الخصوصية والبيانات',
                        subtitle: 'إدارة أمن بياناتك وسياسة خصوصية التطبيق',
                        onTap: () => context.push('/privacy'),
                      ),
                      _NavTile(
                        icon: AppLucideIcons.inbox,
                        title: 'تصدير البيانات',
                        subtitle: 'تصدير عملياتك بصيغة CSV محلي لاحقاً',
                        onTap: () => _showSoon(context, 'تصدير البيانات'),
                      ),
                      _NavTile(
                        icon: AppLucideIcons.inbox,
                        title: 'استيراد العمليات',
                        subtitle: 'استيراد عملياتك من تطبيقات أو ملفات أخرى',
                        onTap: () => _showSoon(context, 'استيراد العمليات'),
                      ),
                      _NavTile(
                        icon: AppLucideIcons.repeat,
                        title: 'ابدأ من جديد',
                        subtitle:
                            'مسح جميع بياناتك المحلية مع إبقاء حسابك نشطاً',
                        onTap: () => context.push('/privacy'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.s5),
                PremiumMotion(
                  delay: const Duration(milliseconds: 240),
                  child: _Section(
                    title: 'المكافآت والدعم',
                    children: [
                      _NavTile(
                        icon: AppLucideIcons.gift,
                        title: 'دعوة الأصدقاء',
                        subtitle: 'شارك التطبيق مع أصدقائك للحصول على مكافآت',
                        trailing: const _SoonBadge(),
                        onTap: () => _showSoon(context, 'دعوة الأصدقاء'),
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
                        subtitle: 'تواصل مع الدعم الفني للإجابة على استفساراتك',
                        onTap: () => _showSoon(context, 'تواصل معنا'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.s6),
                PremiumMotion(
                  delay: const Duration(milliseconds: 280),
                  child: OutlinedButton.icon(
                    onPressed: () => AppSession.instance.signOut(),
                    icon: const Icon(Icons.logout),
                    label: const Text('تسجيل الخروج'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                      foregroundColor: c.danger,
                      side: BorderSide(color: c.danger.withValues(alpha: 0.35)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.s4),
                PremiumMotion(
                  delay: const Duration(milliseconds: 320),
                  child: Center(
                    child: TextButton(
                      onPressed: () => context.push('/privacy'),
                      child: Text('حذف الحساب وكل بياناتي',
                          style: AppTypography.body(c.danger)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _savePrefs(
    WidgetRef ref,
    NotificationPreferences preferences,
  ) async {
    await ref
        .read(saveNotificationPreferencesUseCaseProvider)
        .call(preferences);
    refreshNotificationPreferences(ref);
  }

  Future<void> _saveTheme(WidgetRef ref, ThemeMode mode) async {
    ref.read(themeModeOverrideProvider.notifier).state = mode;
    await ref.read(saveThemeModeUseCaseProvider).call(themeModeToKey(mode));
    refreshUserSettings(ref);
    ref.invalidate(persistedThemeModeProvider);
  }

  String _languageLabel(String value) => switch (value) {
        'en' => 'English',
        _ => 'العربية',
      };

  String _countryLabel(String value) => switch (value) {
        'AE' => 'الإمارات',
        'EG' => 'مصر',
        'KW' => 'الكويت',
        'QA' => 'قطر',
        'BH' => 'البحرين',
        'OM' => 'عمان',
        _ => 'السعودية',
      };

  Future<void> _showSettingsPicker(
    BuildContext context,
    WidgetRef ref, {
    required String title,
    required String current,
    required Map<String, String> values,
    required UserSettingsEntity Function(String value) apply,
  }) {
    final c = context.colors;
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => Directionality(
        textDirection: TextDirection.rtl,
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            AppSpacing.s2,
            AppSpacing.gutter,
            AppSpacing.s6,
          ),
          children: [
            Text(title, style: AppTypography.title2(c.textMain)),
            const SizedBox(height: AppSpacing.s3),
            for (final entry in values.entries)
              RadioListTile<String>(
                value: entry.key,
                groupValue: current,
                title: Text(entry.value),
                onChanged: (value) async {
                  if (value == null) return;
                  await ref
                      .read(userSettingsRepositoryProvider)
                      .saveSettings(apply(value));
                  refreshUserSettings(ref);
                  if (context.mounted) Navigator.of(context).pop();
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showCategoriesSheet(BuildContext context, WidgetRef ref) async {
    final c = context.colors;
    final catalog = await ref.read(categoryCatalogProvider.future);
    if (!context.mounted) return;
    final income = catalog.all.where((item) => item.entity.isIncome).toList();
    final transfers =
        catalog.all.where((item) => item.key == 'transfers').toList();
    final expenses = catalog.all
        .where((item) =>
            !item.entity.isIncome &&
            item.key != 'transfers' &&
            item.key != 'all_expenses')
        .toList();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => Directionality(
        textDirection: TextDirection.rtl,
        child: Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.78,
          ),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutter,
              AppSpacing.s2,
              AppSpacing.gutter,
              AppSpacing.s6,
            ),
            children: [
              Text('التصنيفات', style: AppTypography.title2(c.textMain)),
              Text(
                'التصنيفات الحالية مقسمة حسب نوع الحركة لتسهيل القراءة.',
                style: AppTypography.callout(c.textLight),
              ),
              const SizedBox(height: AppSpacing.s4),
              _CategoryGroup(title: 'مصروفات', items: expenses),
              const SizedBox(height: AppSpacing.s4),
              _CategoryGroup(title: 'دخل', items: income),
              const SizedBox(height: AppSpacing.s4),
              _CategoryGroup(title: 'تحويلات', items: transfers),
            ],
          ),
        ),
      ),
    );
  }

  void _showSoon(BuildContext context, String title) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Directionality(
        textDirection: TextDirection.rtl,
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.gutter,
                AppSpacing.s3,
                AppSpacing.gutter,
                AppSpacing.s6,
              ),
              decoration: BoxDecoration(
                color: isDark
                    ? c.surface.withValues(alpha: 0.9)
                    : Colors.white.withValues(alpha: 0.92),
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(28)),
                border: Border.all(
                  color: Colors.white.withValues(alpha: isDark ? 0.08 : 0.3),
                  width: 1.5,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 44,
                      height: 5,
                      decoration: BoxDecoration(
                        color: c.textLight.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.s3),
                  Text(title, style: AppTypography.title2(c.textMain)),
                  const SizedBox(height: AppSpacing.s2),
                  Text(
                    'الميزة دي متجهزة كمكان في الإعدادات، وهنوصلها بالمنطق الكامل في دفعة قريبة.',
                    style: AppTypography.callout(c.textLight),
                  ),
                  const SizedBox(height: AppSpacing.s4),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: FilledButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: FilledButton.styleFrom(
                        backgroundColor: c.primary,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: Text('تمام',
                          style: AppTypography.bodyStrong(Colors.white)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsHeader extends StatelessWidget {
  const _SettingsHeader({required this.email, required this.method});

  final String email;
  final String method;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        56,
        AppSpacing.gutter,
        AppSpacing.s5,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [c.gradA, c.primary, c.gradB],
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
        ),
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(32)),
        boxShadow: [
          BoxShadow(
            color: c.primary.withValues(alpha: 0.20),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (Navigator.of(context).canPop()) ...[
                const BackButton(color: Colors.white),
                const SizedBox(width: AppSpacing.s2),
              ],
              Expanded(
                child: Text(
                  'الإعدادات والملف الشخصي',
                  style: AppTypography.title1(Colors.white)
                      .copyWith(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s4),
          Container(
            padding: const EdgeInsets.all(AppSpacing.s4),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppRadius.card),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.18),
              ),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: Colors.white.withValues(alpha: 0.25),
                        width: 1.5),
                  ),
                  child: CircleAvatar(
                    radius: 26,
                    backgroundColor: Colors.white.withValues(alpha: 0.15),
                    child:
                        const Icon(Icons.person, size: 28, color: Colors.white),
                  ),
                ),
                const SizedBox(width: AppSpacing.s3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        email,
                        style: AppTypography.bodyStrong(Colors.white),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'الدخول عبر $method',
                        style: AppTypography.caption(Colors.white70),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
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
        Material(
          color: c.surface,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.card),
            side: BorderSide(color: c.border),
          ),
          child: Column(
            children: [
              for (var i = 0; i < children.length; i++) ...[
                children[i],
                if (i != children.length - 1)
                  Divider(height: 1, color: c.border),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _CategoryGroup extends StatelessWidget {
  const _CategoryGroup({required this.title, required this.items});

  final String title;
  final List<CategoryView> items;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: AppTypography.bodyStrong(c.textMain)),
        const SizedBox(height: AppSpacing.s2),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final item in items)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: item.color.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  border: Border.all(color: item.color.withValues(alpha: 0.20)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(item.icon, color: item.color, size: 16),
                    const SizedBox(width: 6),
                    Text(
                      item.nameAr,
                      style: AppTypography.caption(c.textMain)
                          .copyWith(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
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
      padding: const EdgeInsets.all(AppSpacing.s4),
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
          const SizedBox(height: AppSpacing.s4),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(value: ThemeMode.system, label: Text('تلقائي')),
                ButtonSegment(value: ThemeMode.light, label: Text('فاتح')),
                ButtonSegment(value: ThemeMode.dark, label: Text('داكن')),
              ],
              selected: {value},
              onSelectionChanged: (selected) => onChanged(selected.first),
              style: SegmentedButton.styleFrom(
                selectedBackgroundColor: c.primary,
                selectedForegroundColor: Colors.white,
              ),
            ),
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
      contentPadding:
          const EdgeInsets.symmetric(horizontal: AppSpacing.s4, vertical: 2),
      leading: _TileIcon(icon: icon, color: c.primary),
      title: Text(title, style: AppTypography.bodyStrong(c.textMain)),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!, style: AppTypography.caption(c.textLight)),
      trailing:
          trailing ?? Icon(Icons.chevron_left, color: c.textLight, size: 20),
      onTap: onTap,
    );
  }
}

class _SwitchTile extends StatelessWidget {
  const _SwitchTile({
    required this.title,
    required this.icon,
    required this.iconColor,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final IconData icon;
  final Color iconColor;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SwitchListTile(
      contentPadding:
          const EdgeInsets.symmetric(horizontal: AppSpacing.s4, vertical: 2),
      secondary: _TileIcon(icon: icon, color: iconColor),
      value: value,
      onChanged: onChanged,
      activeColor: c.primary,
      title: Text(title, style: AppTypography.bodyStrong(c.textMain)),
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
