import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../../core/backend/supabase_config.dart';
import '../../core/di/app_providers.dart';
import '../../core/security/app_lock_service.dart';
import '../../core/session/app_session.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/theme_mode_provider.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/category_entity.dart';
import '../../domain/entities/engagement_entities.dart';
import '../../domain/entities/supporting_entities.dart';
import '../budgets/budgets_providers.dart';
import '../common/category_catalog.dart';
import '../common/motion.dart';
import '../dashboard/dashboard_providers.dart';
import '../onboarding/method_screen.dart';
import '../transactions/transactions_providers.dart';
import 'data_export.dart';
import 'settings_providers.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  static const _methodLabels = {
    'google': 'Google',
    'apple': 'Apple',
    'email': 'البريد الإلكتروني',
    'guest': 'بدون حساب',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefsAsync = ref.watch(notificationPreferencesProvider);
    final settingsAsync = ref.watch(userSettingsProvider);
    final c = context.colors;
    final session = AppSession.instance;
    final email = session.email ?? '—';
    final method = _methodLabels[session.authMethod] ?? '—';
    final countryValues = <String, String>{
      if (ref.watch(supportedCountriesProvider).valueOrNull
          case final countries?)
        for (final country in countries)
          country.code.toLowerCase(): country.nameAr,
      if ((ref.watch(supportedCountriesProvider).valueOrNull ?? const [])
          .isEmpty) ...const {
        'sa': 'السعودية',
        'ae': 'الإمارات',
        'eg': 'مصر',
        'kw': 'الكويت',
        'qa': 'قطر',
        'bh': 'البحرين',
        'om': 'عمان',
      },
    };
    final currencyValues = <String, String>{
      if (ref.watch(activeCurrenciesProvider).valueOrNull
          case final currencies?)
        for (final currency in currencies)
          currency.code: '${currency.code} - ${currency.nameAr}',
      if ((ref.watch(activeCurrenciesProvider).valueOrNull ?? const [])
          .isEmpty) ...const {
        'SAR': 'SAR - ريال سعودي',
        'AED': 'AED - درهم إماراتي',
        'EGP': 'EGP - جنيه مصري',
        'KWD': 'KWD - دينار كويتي',
        'QAR': 'QAR - ريال قطري',
        'USD': 'USD - دولار',
      },
    };

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
                        icon: Icons.account_balance_wallet_outlined,
                        title: 'الحسابات والمحافظ',
                        subtitle: 'حسابات متعددة، كل واحد بعملته الخاصة',
                        onTap: () => context.push('/accounts'),
                      ),
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
                      if (Platform.isIOS)
                        _NavTile(
                          icon: Icons.ios_share_rounded,
                          title: 'إعداد اختصار آبل',
                          subtitle:
                              'مرّر رسائل البنك تلقائياً إلى مالي عبر Shortcuts',
                          onTap: () => showIosShortcutSheet(context),
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
                          subtitle:
                              countryValues[settings.country.toLowerCase()] ??
                                  _countryLabel(settings.country),
                          onTap: () => _showSettingsPicker(
                            context,
                            ref,
                            title: 'الدولة',
                            current: settings.country,
                            values: countryValues,
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
                            values: {
                              settings.currency:
                                  currencyValues[settings.currency] ??
                                      settings.currency,
                              ...currencyValues,
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
                          onTap: () =>
                              _showQuietHoursSheet(context, ref, prefs),
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
                      settingsAsync.maybeWhen(
                        data: (settings) => _SwitchTile(
                          title: 'إخفاء الأرقام في الواجهة',
                          icon: Icons.visibility_off_outlined,
                          iconColor: c.primary,
                          value: settings.privacyModeEnabled,
                          onChanged: (value) async {
                            await ref
                                .read(userSettingsRepositoryProvider)
                                .saveSettings(settings.copyWith(
                                  privacyModeEnabled: value,
                                ));
                            refreshUserSettings(ref);
                            ref.invalidate(dashboardDataProvider);
                          },
                        ),
                        orElse: () => const SizedBox.shrink(),
                      ),
                      settingsAsync.maybeWhen(
                        data: (settings) => _SwitchTile(
                          title: 'اقتراحات الذكاء الاصطناعي',
                          subtitle: 'للرسائل التي يعجز المحرك عن تحليلها، '
                              'نرسل نصاً مُعقَّماً (بدون أرقام بطاقات أو أسماء) '
                              'لخدمة ذكاء اصطناعي. المبالغ والتواريخ تبقى على جهازك.',
                          icon: Icons.auto_awesome_outlined,
                          iconColor: c.accent,
                          value: settings.aiConsentGranted,
                          onChanged: (value) async {
                            await ref
                                .read(userSettingsRepositoryProvider)
                                .saveSettings(settings.copyWith(
                                  aiConsentGranted: value,
                                ));
                            refreshUserSettings(ref);
                          },
                        ),
                        orElse: () => const SizedBox.shrink(),
                      ),
                      const _AppLockTile(),
                      _NavTile(
                        icon: AppLucideIcons.inbox,
                        title: 'تصدير البيانات',
                        subtitle: 'مشاركة ملف CSV بكل عملياتك',
                        onTap: () => exportTransactionsCsv(context, ref),
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
                        subtitle: 'انسخ رسالة دعوة مختصرة وشاركها بطريقتك',
                        onTap: () => _copyInviteText(context),
                      ),
                      _NavTile(
                        icon: AppLucideIcons.alertTriangle,
                        title: 'عن التطبيق',
                        subtitle: 'مالي / Mali',
                        onTap: () => _showAboutApp(context),
                      ),
                      _NavTile(
                        icon: AppLucideIcons.receipt,
                        title: 'تواصل معنا',
                        subtitle: 'تواصل مع الدعم الفني للإجابة على استفساراتك',
                        onTap: () => _showContactSupport(context),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.s6),
                PremiumMotion(
                  delay: const Duration(milliseconds: 280),
                  child: OutlinedButton.icon(
                    onPressed: () => _signOut(),
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

  Future<void> _signOut() async {
    if (SupabaseConfig.isConfigured) {
      try {
        await supabase.Supabase.instance.client.auth.signOut();
      } catch (_) {
        // Local sign-out still protects the device even if network sign-out fails.
      }
    }
    await AppSession.instance.signOut();
  }

  String _languageLabel(String value) => switch (value) {
        'en' => 'English',
        _ => 'العربية',
      };

  String _countryLabel(String value) => switch (value.toLowerCase()) {
        'ae' => 'الإمارات',
        'eg' => 'مصر',
        'kw' => 'الكويت',
        'qa' => 'قطر',
        'bh' => 'البحرين',
        'om' => 'عمان',
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
                groupValue: title == 'الدولة' ? current.toLowerCase() : current,
                secondary: title == 'الدولة'
                    ? _FlagAvatar(code: entry.key.toLowerCase(), size: 32)
                    : null,
                title: Text(
                  entry.value,
                  style: AppTypography.bodyStrong(c.textMain),
                ),
                subtitle: title == 'الدولة'
                    ? Text(
                        entry.key.toUpperCase(),
                        style: AppTypography.caption(c.textLight),
                      )
                    : null,
                activeColor: c.primary,
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
                'أضف أو عدّل التصنيفات التي تظهر في العمليات والتقارير.',
                style: AppTypography.callout(c.textLight),
              ),
              const SizedBox(height: AppSpacing.s4),
              FilledButton.icon(
                onPressed: () => _showCategoryForm(context, ref),
                icon: const Icon(Icons.add),
                label: const Text('إضافة تصنيف'),
              ),
              const SizedBox(height: AppSpacing.s4),
              _CategoryGroup(
                title: 'مصروفات',
                items: expenses,
                onEdit: (item) => _showCategoryForm(context, ref, item: item),
                onDelete: (item) => _deleteCategory(context, ref, item),
              ),
              const SizedBox(height: AppSpacing.s4),
              _CategoryGroup(
                title: 'دخل',
                items: income,
                onEdit: (item) => _showCategoryForm(context, ref, item: item),
                onDelete: (item) => _deleteCategory(context, ref, item),
              ),
              const SizedBox(height: AppSpacing.s4),
              _CategoryGroup(
                title: 'تحويلات',
                items: transfers,
                onEdit: (item) => _showCategoryForm(context, ref, item: item),
                onDelete: (item) => _deleteCategory(context, ref, item),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showCategoryForm(
    BuildContext context,
    WidgetRef ref, {
    CategoryView? item,
  }) async {
    final c = context.colors;
    final name = TextEditingController(text: item?.nameAr ?? '');
    var icon = item?.entity.icon ?? 'shapes';
    var color = item?.entity.color ?? '#9E9E9E';
    var isIncome = item?.entity.isIncome ?? false;
    final isEditing = item != null;
    const icons = [
      'shapes',
      'utensils-crossed',
      'shopping-basket',
      'shopping-bag',
      'car-taxi-front',
      'receipt-text',
      'wallet-cards',
      'banknote',
      'coffee',
      'gift',
      'house',
      'plane',
      'heart-pulse',
      'graduation-cap',
      'arrow-left-right',
    ];
    const colors = [
      '#9E9E9E',
      '#FF7043',
      '#43A047',
      '#1E88E5',
      '#8E24AA',
      '#00C853',
      '#00897B',
      '#D81B60',
      '#546E7A',
      '#FB8C00',
    ];

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => Directionality(
          textDirection: TextDirection.rtl,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              AppSpacing.gutter,
              AppSpacing.s2,
              AppSpacing.gutter,
              MediaQuery.of(context).viewInsets.bottom + AppSpacing.s6,
            ),
            child: ListView(
              shrinkWrap: true,
              children: [
                Text(
                  isEditing ? 'تعديل تصنيف' : 'إضافة تصنيف',
                  style: AppTypography.title2(c.textMain),
                ),
                const SizedBox(height: AppSpacing.s4),
                TextField(
                  controller: name,
                  decoration: const InputDecoration(
                    labelText: 'اسم التصنيف',
                    prefixIcon: Icon(Icons.label_outline),
                  ),
                ),
                const SizedBox(height: AppSpacing.s3),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: isIncome,
                  onChanged: (value) => setState(() => isIncome = value),
                  title: const Text('تصنيف دخل'),
                ),
                const SizedBox(height: AppSpacing.s3),
                DropdownButtonFormField<String>(
                  value: icon,
                  decoration: const InputDecoration(
                    labelText: 'الأيقونة',
                    prefixIcon: Icon(Icons.emoji_symbols_outlined),
                  ),
                  items: icons
                      .map(
                        (value) => DropdownMenuItem(
                          value: value,
                          child: Text(value),
                        ),
                      )
                      .toList(),
                  onChanged: (value) => setState(() => icon = value ?? icon),
                ),
                const SizedBox(height: AppSpacing.s3),
                DropdownButtonFormField<String>(
                  value: color,
                  decoration: const InputDecoration(
                    labelText: 'اللون',
                    prefixIcon: Icon(Icons.palette_outlined),
                  ),
                  items: colors
                      .map(
                        (value) => DropdownMenuItem(
                          value: value,
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 8,
                                backgroundColor: Formatters.colorFromHex(value),
                              ),
                              const SizedBox(width: 8),
                              Text(value),
                            ],
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (value) => setState(() => color = value ?? color),
                ),
                const SizedBox(height: AppSpacing.s5),
                FilledButton(
                  onPressed: () async {
                    final title = name.text.trim();
                    if (title.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('اكتب اسم التصنيف.')),
                      );
                      return;
                    }
                    final repo = ref.read(categoryRepositoryProvider);
                    if (item == null) {
                      await repo.createCategory(
                        nameAr: title,
                        icon: icon,
                        color: color,
                        isIncome: isIncome,
                      );
                    } else {
                      await repo.updateCategory(
                        CategoryEntity(
                          id: item.id,
                          key: item.key,
                          nameAr: title,
                          icon: icon,
                          color: color,
                          isIncome: isIncome,
                          sort: item.entity.sort,
                        ),
                      );
                    }
                    _refreshCategoryDependents(ref);
                    if (context.mounted) Navigator.of(context).pop();
                  },
                  child: Text(isEditing ? 'حفظ التعديلات' : 'إضافة'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    name.dispose();
  }

  Future<void> _deleteCategory(
    BuildContext context,
    WidgetRef ref,
    CategoryView item,
  ) async {
    if (item.entity.sort < 0) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('حذف التصنيف؟'),
        content: const Text(
          'سيتم نقل عملياته إلى «أخرى» أو «دخل»، وحذف أي ميزانية مرتبطة به.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(categoryRepositoryProvider).deleteCategory(item.id);
    _refreshCategoryDependents(ref);
  }

  void _refreshCategoryDependents(WidgetRef ref) {
    ref.invalidate(categoryCatalogProvider);
    refreshTransactions(ref);
    refreshBudgets(ref);
    ref.invalidate(dashboardDataProvider);
  }

  Future<void> _showQuietHoursSheet(
    BuildContext context,
    WidgetRef ref,
    NotificationPreferences preferences,
  ) {
    final c = context.colors;
    var start = preferences.quietHoursStartHour;
    var end = preferences.quietHoursEndHour;
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => Directionality(
          textDirection: TextDirection.rtl,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutter,
              AppSpacing.s2,
              AppSpacing.gutter,
              AppSpacing.s6,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('ساعات الهدوء', style: AppTypography.title2(c.textMain)),
                const SizedBox(height: AppSpacing.s2),
                Text(
                  'نؤجل الإشعارات المجدولة خلال هذه الفترة لأول وقت مسموح.',
                  style: AppTypography.callout(c.textLight),
                ),
                const SizedBox(height: AppSpacing.s4),
                Row(
                  children: [
                    Expanded(
                      child: _HourPicker(
                        label: 'تبدأ',
                        value: start,
                        onChanged: (value) => setState(() => start = value),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.s3),
                    Expanded(
                      child: _HourPicker(
                        label: 'تنتهي',
                        value: end,
                        onChanged: (value) => setState(() => end = value),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.s5),
                SizedBox(
                  height: 52,
                  child: FilledButton(
                    onPressed: () async {
                      await _savePrefs(
                        ref,
                        preferences.copyWith(
                          quietHoursStartHour: start,
                          quietHoursEndHour: end,
                        ),
                      );
                      if (context.mounted) Navigator.of(context).pop();
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: c.primary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    child: Text(
                      'حفظ',
                      style: AppTypography.bodyStrong(Colors.white),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _copyInviteText(BuildContext context) async {
    await Clipboard.setData(
      const ClipboardData(
        text:
            'جرّب مالي: تطبيق عربي يساعدك تفهم مصروفاتك من رسائل البنك وتتابع ميزانيتك بسهولة.',
      ),
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('تم نسخ رسالة الدعوة.')),
    );
  }

  void _showAboutApp(BuildContext context) {
    _showInfoSheet(
      context,
      title: 'عن التطبيق',
      body:
          'مالي لتتبع المصروفات من رسائل البنك والإدخال اليدوي. بياناتك المالية تبقى على جهازك افتراضياً، والنسخ الاحتياطي اختياري ومشفّر end-to-end عند تفعيله.',
      actionLabel: 'تمام',
    );
  }

  void _showContactSupport(BuildContext context) {
    _showInfoSheet(
      context,
      title: 'تواصل معنا',
      body:
          'للدعم أو الملاحظات انسخ البريد وأرسل لنا تفاصيل المشكلة، نوع الجهاز، وخطوات تكرارها.',
      actionLabel: 'نسخ البريد',
      onAction: () async {
        await Clipboard.setData(
          const ClipboardData(text: 'support@money-companion.app'),
        );
      },
    );
  }

  void _showInfoSheet(
    BuildContext context, {
    required String title,
    required String body,
    required String actionLabel,
    Future<void> Function()? onAction,
  }) {
    final c = context.colors;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => Directionality(
        textDirection: TextDirection.rtl,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            AppSpacing.s2,
            AppSpacing.gutter,
            AppSpacing.s6,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: AppTypography.title2(c.textMain)),
              const SizedBox(height: AppSpacing.s2),
              Text(body, style: AppTypography.callout(c.textLight)),
              const SizedBox(height: AppSpacing.s4),
              SizedBox(
                height: 52,
                child: FilledButton(
                  onPressed: () async {
                    await onAction?.call();
                    if (context.mounted) Navigator.of(context).pop();
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: c.primary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: Text(
                    actionLabel,
                    style: AppTypography.bodyStrong(Colors.white),
                  ),
                ),
              ),
            ],
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
    const headerText = Colors.white;
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        56,
        AppSpacing.gutter,
        AppSpacing.s5,
      ),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [
            Color(0xFF046E9B),
            Color(0xFF034E73),
            Color(0xFF012438),
          ],
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
        ),
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(32)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF034F73).withValues(alpha: 0.25),
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
                  style: AppTypography.title1(headerText)
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
                        style: AppTypography.bodyStrong(headerText),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'الدخول عبر $method',
                        style: AppTypography.caption(
                          headerText.withValues(alpha: 0.72),
                        ),
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
  const _CategoryGroup({
    required this.title,
    required this.items,
    required this.onEdit,
    required this.onDelete,
  });

  final String title;
  final List<CategoryView> items;
  final ValueChanged<CategoryView> onEdit;
  final ValueChanged<CategoryView> onDelete;

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
              for (var i = 0; i < items.length; i++) ...[
                ListTile(
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: AppSpacing.s4),
                  leading: CircleAvatar(
                    backgroundColor: items[i].color.withValues(alpha: 0.12),
                    child: Icon(items[i].icon, color: items[i].color, size: 18),
                  ),
                  title: Text(items[i].nameAr),
                  subtitle: Text(items[i].key),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'تعديل',
                        onPressed: () => onEdit(items[i]),
                        icon: const Icon(Icons.edit_outlined),
                      ),
                      if (items[i].entity.sort >= 0)
                        IconButton(
                          tooltip: 'حذف',
                          onPressed: () => onDelete(items[i]),
                          icon: Icon(Icons.delete_outline, color: c.danger),
                        ),
                    ],
                  ),
                ),
                if (i != items.length - 1) Divider(height: 1, color: c.border),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _FlagAvatar extends StatelessWidget {
  const _FlagAvatar({required this.code, required this.size});

  final String code;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * 0.08),
      decoration: BoxDecoration(
        color: c.surface,
        shape: BoxShape.circle,
        border: Border.all(color: c.border),
      ),
      child: ClipOval(
        child: SvgPicture.asset(
          'assets/flags/$code.svg',
          fit: BoxFit.cover,
        ),
      ),
    );
  }
}

class _AppLockTile extends StatefulWidget {
  const _AppLockTile();

  @override
  State<_AppLockTile> createState() => _AppLockTileState();
}

class _AppLockTileState extends State<_AppLockTile> {
  bool _enabled = false;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final enabled = await AppLockService.instance.isEnabled();
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _loading = false;
    });
  }

  Future<void> _setEnabled(bool value) async {
    if (_busy) return;
    setState(() => _busy = true);
    final ok = await AppLockService.instance.setEnabled(value);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) _enabled = value;
    });
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('تعذر تفعيل القفل. تأكد من إعداد بصمة أو رمز للجهاز.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return _SwitchTile(
      title: 'قفل التطبيق',
      icon: Icons.lock_outline_rounded,
      iconColor: c.primary,
      value: _enabled,
      onChanged: _loading || _busy ? (_) {} : _setEnabled,
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
                selectedForegroundColor:
                    Theme.of(context).brightness == Brightness.dark
                        ? Colors.black
                        : Colors.white,
                foregroundColor: c.textMain,
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
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
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
      trailing: Icon(Icons.chevron_left, color: c.textLight, size: 20),
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
    this.subtitle,
  });

  final String title;
  final String? subtitle;
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
      subtitle: subtitle == null
          ? null
          : Text(subtitle!, style: AppTypography.caption(c.textLight)),
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

class _HourPicker extends StatelessWidget {
  const _HourPicker({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppTypography.subhead(c.textLight)),
        const SizedBox(height: AppSpacing.s2),
        DropdownButtonFormField<int>(
          value: value,
          decoration: InputDecoration(
            filled: true,
            fillColor: c.surface2.withValues(alpha: 0.55),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(color: c.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(color: c.border),
            ),
          ),
          items: [
            for (var hour = 0; hour < 24; hour++)
              DropdownMenuItem(
                value: hour,
                child: Text('${hour.toString().padLeft(2, '0')}:00'),
              ),
          ],
          onChanged: (value) {
            if (value != null) onChanged(value);
          },
        ),
      ],
    );
  }
}
