import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../../core/auth/auth_service.dart';
import '../../core/backend/supabase_config.dart';
import '../../core/privacy/data_wipe_service.dart';
import '../../core/di/app_providers.dart';
import '../planning_sync/planning_conflicts_sheet.dart';
import '../../core/theme/app_shadows.dart';
import '../../data/catalog/catalog_daos.dart';
import '../../core/security/app_lock_service.dart';
import '../../core/session/app_session.dart';
import '../../core/session/unsynced_inventory.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/theme_mode_controller.dart';
import '../../core/theme/widgets/navy_sheet_theme.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/category_glyph.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/category_entity.dart';
import '../../domain/entities/engagement_entities.dart';
import '../../domain/entities/supporting_entities.dart';
import '../budgets/budgets_providers.dart';
import '../cards/my_cards_screen.dart';
import '../plans/plans_screen.dart';
import '../common/app_avatar.dart';
import '../common/category_catalog.dart';
import '../../core/theme/widgets/calm_page_header.dart';
import '../common/motion.dart';
import '../dashboard/dashboard_providers.dart';
import '../capture/services/local_notification_service.dart';
import '../onboarding/ios_shortcut_guide.dart';
import '../transactions/transactions_providers.dart';
import 'settings_providers.dart';

/// maybeWhen that keeps rendering the last loaded value during a reload, so the
/// frequent `user_settings` writes (sync, notification history, journey) don't
/// flash the settings cards back to their skeleton/placeholder — the settings
/// screen flicker. Falls back only on a genuine first load with no value yet.
extension _AsyncReloadSafe<T> on AsyncValue<T> {
  R dataOr<R>(R Function(T value) onData, R Function() orElse) {
    final value = valueOrNull;
    return value != null ? onData(value) : orElse();
  }
}

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key, this.showBackButton = false});

  final bool showBackButton;

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  String _profileName(UserSettingsEntity? s, String email) {
    final n = s?.displayName?.trim() ?? '';
    if (n.isNotEmpty) return n;
    final local = email.split('@').first.trim();
    if (local.isEmpty || local == '—') return 'صديق مالي';
    return local.replaceAll('.', ' ').replaceAll('_', ' ');
  }

  String _countryLabel(
      UserSettingsEntity s, List<RemoteCountry> countries, bool loading) {
    final code = s.country.toUpperCase();
    for (final country in countries) {
      if (country.code.toUpperCase() == code) {
        return '${country.flagEmoji} ${country.nameAr}';
      }
    }
    return loading ? 'تحميل الدول...' : s.country;
  }

  String _currencyLabel(
      UserSettingsEntity s, List<RemoteCurrency> currencies, bool loading) {
    final code = s.currency.toUpperCase();
    for (final currency in currencies) {
      if (currency.code.toUpperCase() == code) {
        return '${currency.code} · ${currency.nameAr}';
      }
    }
    return loading ? 'تحميل العملات...' : s.currency;
  }

  void _editCountry(
    BuildContext context,
    WidgetRef ref,
    UserSettingsEntity settings,
    List<RemoteCountry> countries,
    List<RemoteCurrency> currencies,
  ) {
    _showSettingsPicker(
      context,
      ref,
      title: 'الدولة',
      current: settings.country.toUpperCase(),
      values: _countryValues(countries),
      save: (value) async {
        final country = value.toUpperCase();
        final currency = _preferredCurrencyForCountry(
            country, currencies, settings.currency);
        await ref
            .read(saveCountryCurrencyUseCaseProvider)
            .call(country, currency);
      },
    );
  }

  void _editCurrency(
    BuildContext context,
    WidgetRef ref,
    UserSettingsEntity settings,
    List<RemoteCurrency> currencies,
  ) {
    _showSettingsPicker(
      context,
      ref,
      title: 'العملة الأساسية',
      current: settings.currency.toUpperCase(),
      values: _currencyValuesForCountry(settings.country, currencies),
      save: (value) async {
        await ref.read(saveCountryCurrencyUseCaseProvider).call(
              settings.country.toUpperCase(),
              value.toUpperCase(),
            );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final prefsAsync = ref.watch(notificationPreferencesProvider);
    final captureHealthAsync = ref.watch(captureHealthStatusProvider);
    final settingsAsync = ref.watch(userSettingsProvider);
    final settings = settingsAsync.valueOrNull;
    final countriesAsync = ref.watch(supportedCountriesProvider);
    final currenciesAsync = ref.watch(activeCurrenciesProvider);
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final session = AppSession.instance;
    final email = session.email ?? '—';
    final countries = countriesAsync.valueOrNull ?? const <RemoteCountry>[];
    final currencies = currenciesAsync.valueOrNull ?? const <RemoteCurrency>[];

    return Scaffold(
      backgroundColor: c.bg,
      body: Stack(
        children: [
          // Ambient glow for dark mode (matches dashboard)
          if (isDark) ...[
            Positioned(
              right: -100,
              top: -100,
              width: 320,
              height: 320,
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      c.cta.withValues(alpha: 0.05),
                      c.cta.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              left: -120,
              bottom: -120,
              width: 360,
              height: 360,
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      c.cta.withValues(alpha: 0.035),
                      c.cta.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
          ],
          CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: _SettingsHeader(
                  name: _profileName(settings, email),
                  contact: (settings?.phoneNumber?.trim().isNotEmpty ?? false)
                      ? settings!.phoneNumber!.trim()
                      : email,
                  avatarPath: settings?.avatarPath?.trim() ?? '',
                  onBack: widget.showBackButton
                      ? () {
                          if (context.canPop()) context.pop();
                        }
                      : null,
                  onAvatarTap: settings == null
                      ? null
                      : () => _pickProfileImage(context, ref, settings),
                  onNameTap: settings == null
                      ? null
                      : () => _showProfileTextSheet(
                            context,
                            ref,
                            title: 'الاسم',
                            label: 'اسمك في التطبيق',
                            initialValue: settings.displayName ?? '',
                            apply: (value) =>
                                settings.copyWith(displayName: value.trim()),
                          ),
                ),
              ),
              // الذوبان لازم يلفّ المحتوى كامل العرض ومن غير مسافة فوقه — لو
              // اتحط جوّه الـ padding بيبقى شريط أزرق مقصوص من الجناب وبحافة
              // حادّة تحت الهيدر.
              SliverToBoxAdapter(
                child: MeltTail(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.gutter,
                      AppSpacing.s4,
                      AppSpacing.gutter,
                      120,
                    ),
                    child: Column(children: [
                      if (settings != null) ...[
                        _Section(
                          title: 'الحساب',
                          children: [
                            _NavTile(
                              icon: AppLucideIcons.smartphone,
                              title: 'رقم الموبايل',
                              subtitle:
                                  (settings.phoneNumber?.trim().isNotEmpty ??
                                          false)
                                      ? settings.phoneNumber!.trim()
                                      : 'أضف رقمك',
                              onTap: () => _showProfileTextSheet(
                                context,
                                ref,
                                title: 'رقم الموبايل',
                                label: 'رقم الموبايل',
                                keyboardType: TextInputType.phone,
                                initialValue: settings.phoneNumber ?? '',
                                apply: (value) => settings.copyWith(
                                    phoneNumber: value.trim()),
                              ),
                            ),
                            _NavTile(
                              icon: AppLucideIcons.flag,
                              title: 'الدولة',
                              subtitle: _countryLabel(settings, countries,
                                  countriesAsync.isLoading),
                              onTap: countries.isEmpty
                                  ? null
                                  : () => _editCountry(context, ref, settings,
                                      countries, currencies),
                            ),
                            _NavTile(
                              icon: AppLucideIcons.banknote,
                              title: 'العملة الأساسية',
                              subtitle: _currencyLabel(settings, currencies,
                                  currenciesAsync.isLoading),
                              onTap: currencies.isEmpty
                                  ? null
                                  : () => _editCurrency(
                                      context, ref, settings, currencies),
                            ),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.s4),
                      ],
                      _buildGeneralTab(context, ref, settingsAsync),
                      const SizedBox(height: AppSpacing.s4),
                      _buildNotificationsTab(
                        context,
                        ref,
                        prefsAsync,
                        captureHealthAsync,
                      ),
                      const SizedBox(height: AppSpacing.s4),
                      _buildDataTab(context, ref, settingsAsync),
                    ]),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildGeneralTab(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<UserSettingsEntity> settingsAsync,
  ) {
    return Column(
      children: [
        PremiumMotion(
            delay: const Duration(milliseconds: 40),
            child: _Section(
              title: 'المظهر',
              description: 'فاتح، داكن، أو حسب النظام',
              children: [
                _ThemeModeSelector(
                  value: ref.watch(themeModeProvider),
                  onChanged: (mode) =>
                      ref.read(themeModeProvider.notifier).set(mode),
                ),
              ],
            )),
        const SizedBox(height: AppSpacing.s3),
        PremiumMotion(
            delay: const Duration(milliseconds: 80),
            child: _Section(
              title: 'إدارة أموالك',
              description: 'كل الأدوات المالية في مكان واحد',
              children: [
                // MALI-022: surface unresolved multi-device conflicts so they
                // are no longer stuck/invisible. Shown only when some exist.
                if ((ref.watch(conflictsProvider).valueOrNull ?? const [])
                    .isNotEmpty)
                  _NavTile(
                    icon: AppLucideIcons.cloudOff,
                    title: 'تعارضات المزامنة',
                    subtitle: 'عناصر عُدّلت على أكثر من جهاز — بحاجة لقرارك',
                    onTap: () => PlanningConflictsSheet.show(context),
                  ),
                _NavTile(
                  icon: AppLucideIcons.wallet,
                  title: 'الحسابات والمحافظ',
                  subtitle: 'حسابات متعددة، كل واحد بعملته الخاصة',
                  onTap: () => context.push('/accounts'),
                ),
                _NavTile(
                  icon: AppLucideIcons.creditCard,
                  title: 'كل البطاقات',
                  subtitle: 'نظرة عامة على بطاقاتك مجمّعة حسب الحساب',
                  onTap: () => MyCardsScreen.open(context),
                ),
                _NavTile(
                  icon: AppLucideIcons.receipt,
                  title: 'الاشتراكات والفواتير',
                  subtitle: 'التزاماتك الدورية ومواعيد السداد',
                  onTap: () => context.push('/subscriptions'),
                ),
                _NavTile(
                  icon: AppLucideIcons.luggage,
                  title: 'الخطط',
                  subtitle: 'ميزانية رحلة أو مناسبة تتابع نفسها',
                  onTap: () => PlansScreen.open(context),
                ),
                _NavTile(
                  icon: AppLucideIcons.barChart3,
                  title: 'الرؤى والتقارير',
                  subtitle: 'اتجاهات صرفك وتصنيفاتك ومتاجرك',
                  onTap: () => context.push('/reports'),
                ),
                _NavTile(
                  icon: AppLucideIcons.trophy,
                  title: 'الإنجازات والمستوى',
                  subtitle: 'شارات ومستويات تشجع عادة المتابعة',
                  onTap: () => context.push('/achievements'),
                ),
                _NavTile(
                  icon: AppLucideIcons.arrowLeftRight,
                  title: 'تأكيد عملة الميزانيات والأهداف',
                  subtitle: 'راجع عملة بيانات التخطيط القديمة بأمان',
                  onTap: () =>
                      context.push('/settings/planning-currency-repair'),
                ),
                _NavTile(
                  icon: AppLucideIcons.inbox,
                  title: 'التصنيفات',
                  subtitle: 'نظم المصروفات والدخل والتحويلات',
                  onTap: () => _showCategoriesSheet(context, ref),
                ),
                if (Platform.isIOS)
                  _NavTile(
                    icon: AppLucideIcons.share,
                    title: 'اختصار آبل',
                    subtitle: 'مرر رسائل البنك إلى قرش عبر Shortcuts',
                    onTap: () => showIosShortcutSheet(context),
                  ),
              ],
            )),
        const SizedBox(height: AppSpacing.s3),
        PremiumMotion(
            delay: const Duration(milliseconds: 120),
            child: _Section(
              title: 'المكافآت والدعم',
              children: [
                _NavTile(
                  icon: AppLucideIcons.gift,
                  title: 'دعوة الأصدقاء',
                  subtitle: 'انسخ رسالة الدعوة وشاركها',
                  onTap: () => _copyInviteText(context),
                ),
                _NavTile(
                  icon: AppLucideIcons.receipt,
                  title: 'تواصل معنا',
                  subtitle: 'الدعم الفني والإجابة على استفساراتك',
                  onTap: () => _showContactSupport(context),
                ),
                _NavTile(
                  icon: AppLucideIcons.info,
                  title: 'عن قرش',
                  subtitle: 'معلومات التطبيق والإصدار',
                  onTap: () => _showAboutApp(context),
                ),
              ],
            )),
      ],
    );
  }

  Widget _buildNotificationsTab(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<NotificationPreferences> prefsAsync,
    AsyncValue<CaptureHealthStatus> captureHealthAsync,
  ) {
    final c = context.colors;
    return prefsAsync.when(
      skipLoadingOnReload: true,
      loading: () => const _SettingsLoadingState(),
      error: (error, _) => const _SettingsErrorState(),
      data: (prefs) => Column(
        children: [
          PremiumMotion(
              delay: const Duration(milliseconds: 80),
              child: _Section(
                title: 'رصد العمليات',
                description: 'حالة الربط مع رسائل البنك واختصار آبل',
                children: [
                  captureHealthAsync.dataOr(
                    (status) => _CaptureHealthTile(status: status),
                    () => const SizedBox.shrink(),
                  ),
                  const _TrustNoticeTile(
                    text:
                        'قرش يرسل إشعارات لمساعدتك، ولا يقرأ إشعارات البنك أو رسائل SMS من النظام.',
                  ),
                  _SwitchTile(
                    title: 'تأكيد العمليات الملتقطة',
                    icon: AppLucideIcons.messageSquare,
                    value: prefs.captureReview,
                    onChanged: (value) => _savePrefs(
                      ref,
                      prefs.copyWith(captureReview: value),
                    ),
                  ),
                  _SwitchTile(
                    title: 'إشعار عند التقاط عملية',
                    icon: AppLucideIcons.bellRing,
                    iconColor: c.cta,
                    value: prefs.captureLight,
                    onChanged: (value) => _savePrefs(
                      ref,
                      prefs.copyWith(captureLight: value),
                    ),
                  ),
                  // MALI-019 §6 — lock-screen privacy.
                  _SwitchTile(
                    title: 'إخفاء التفاصيل الحساسة على شاشة القفل',
                    icon: AppLucideIcons.lock,
                    value: prefs.hideLockScreenContent,
                    onChanged: (value) => _savePrefs(
                      ref,
                      prefs.copyWith(hideLockScreenContent: value),
                    ),
                  ),
                ],
              )),
          const SizedBox(height: AppSpacing.s3),
          PremiumMotion(
              delay: const Duration(milliseconds: 100),
              child: _Section(
                title: 'تنبيهاتك',
                children: [
                  _SwitchTile(
                    title: 'رسائل ونصائح قرش',
                    icon: AppLucideIcons.megaphone,
                    value: prefs.marketingMessages,
                    onChanged: (value) => _savePrefs(
                      ref,
                      prefs.copyWith(marketingMessages: value),
                    ),
                  ),
                  _SwitchTile(
                    title: 'تنبيه 80% من الميزانية',
                    icon: AppLucideIcons.alertTriangle,
                    iconColor: c.accent,
                    value: prefs.budgetWarning,
                    onChanged: (value) => _savePrefs(
                      ref,
                      prefs.copyWith(budgetWarning: value),
                    ),
                  ),
                  _SwitchTile(
                    title: 'تنبيه تجاوز الميزانية',
                    icon: AppLucideIcons.alertCircle,
                    iconColor: c.danger,
                    value: prefs.budgetOver,
                    onChanged: (value) => _savePrefs(
                      ref,
                      prefs.copyWith(budgetOver: value),
                    ),
                  ),
                  _SwitchTile(
                    title: 'التقرير الأسبوعي',
                    icon: AppLucideIcons.lineChart,
                    value: prefs.weeklyReport,
                    onChanged: (value) => _savePrefs(
                      ref,
                      prefs.copyWith(weeklyReport: value),
                    ),
                  ),
                  _SwitchTile(
                    title: 'تذكير الاشتراكات والفواتير',
                    icon: AppLucideIcons.calendarCheck,
                    iconColor: c.cta,
                    value: prefs.subscriptionReminder,
                    onChanged: (value) => _savePrefs(
                      ref,
                      prefs.copyWith(subscriptionReminder: value),
                    ),
                  ),
                  _SwitchTile(
                    title: 'احتفالات الأهداف',
                    icon: AppLucideIcons.flag,
                    iconColor: c.success,
                    value: prefs.goalMilestone,
                    onChanged: (value) => _savePrefs(
                      ref,
                      prefs.copyWith(goalMilestone: value),
                    ),
                  ),
                  _SwitchTile(
                    title: 'تنبيهات الإنجازات',
                    icon: AppLucideIcons.trophy,
                    iconColor: c.success,
                    value: prefs.achievements,
                    onChanged: (value) => _savePrefs(
                      ref,
                      prefs.copyWith(achievements: value),
                    ),
                  ),
                  _SwitchTile(
                    title: 'تذكير السلسلة',
                    icon: AppLucideIcons.flame,
                    iconColor: c.accent,
                    value: prefs.streakReminder,
                    onChanged: (value) => _savePrefs(
                      ref,
                      prefs.copyWith(streakReminder: value),
                    ),
                  ),
                  _SwitchTile(
                    icon: AppLucideIcons.moon,
                    iconColor: c.textMuted,
                    title: 'ساعات الهدوء',
                    subtitle: prefs.quietHoursEnabled
                        ? '${prefs.quietHoursStartHour}:00 - ${prefs.quietHoursEndHour}:00'
                        : 'معطّل',
                    value: prefs.quietHoursEnabled,
                    onChanged: (value) => _savePrefs(
                      ref,
                      prefs.copyWith(quietHoursEnabled: value),
                    ),
                  ),
                  if (prefs.quietHoursEnabled)
                    _NavTile(
                      icon: AppLucideIcons.clock,
                      title: 'تعديل وقت الهدوء',
                      subtitle:
                          '${prefs.quietHoursStartHour}:00 - ${prefs.quietHoursEndHour}:00',
                      onTap: () => _showQuietHoursSheet(context, ref, prefs),
                    ),
                ],
              )),
          const SizedBox(height: AppSpacing.s3),
          PremiumMotion(
              delay: const Duration(milliseconds: 120),
              child: _Section(
                title: 'أدوات الإشعارات',
                children: [
                  _NavTile(
                    icon: AppLucideIcons.bellPlus,
                    title: 'اختبار إشعارات قرش',
                    subtitle: 'أرسل إشعارًا تجريبيًا إلى هذا الجهاز',
                    onTap: () => _sendTestNotification(context),
                  ),
                  _NavTile(
                    icon: AppLucideIcons.inbox,
                    title: 'مركز رسائل قرش',
                    subtitle: 'الإشعارات والحملات والإعلانات السابقة',
                    onTap: () => context.push('/announcements'),
                  ),
                ],
              )),
        ],
      ),
    );
  }

  Widget _buildDataTab(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<UserSettingsEntity> settingsAsync,
  ) {
    final c = context.colors;
    return Column(
      children: [
        PremiumMotion(
            delay: const Duration(milliseconds: 80),
            child: _Section(
              title: 'نقل البيانات',
              description: 'بياناتك المالية تظل تحت سيطرتك',
              children: [
                _NavTile(
                  icon: AppLucideIcons.folderOpen,
                  title: 'استيراد ملف',
                  subtitle: 'CSV من أي تطبيق أو ZIP صادر من قرش',
                  onTap: () => context.push('/data-transfer?intent=import'),
                ),
                _NavTile(
                  icon: AppLucideIcons.table,
                  title: 'تصدير العمليات CSV',
                  subtitle: 'ملف بسيط لكل عملياتك',
                  onTap: () =>
                      context.push('/data-transfer?intent=transactions'),
                ),
                _NavTile(
                  icon: AppLucideIcons.archive,
                  title: 'تصدير كل بيانات قرش',
                  subtitle: 'حزمة ZIP قابلة للنقل والاستعادة',
                  onTap: () => context.push('/data-transfer?intent=package'),
                ),
              ],
            )),
        const SizedBox(height: AppSpacing.s3),
        PremiumMotion(
            delay: const Duration(milliseconds: 100),
            child: _Section(
              title: 'الأمان والخصوصية',
              children: [
                _NavTile(
                  icon: AppLucideIcons.heartPulse,
                  title: 'الخصوصية والبيانات',
                  subtitle: 'أمان بياناتك وسياسة الخصوصية',
                  onTap: () => context.push('/privacy'),
                ),
                settingsAsync.dataOr(
                  (settings) => _SwitchTile(
                    title: 'إخفاء الأرقام في الواجهة',
                    icon: AppLucideIcons.eyeOff,
                    value: settings.privacyModeEnabled,
                    onChanged: (value) async {
                      await ref
                          .read(userSettingsRepositoryProvider)
                          .saveSettings(settings.copyWith(
                            privacyModeEnabled: value,
                          ));
                      // dbRevision (from saveSettings) rebuilds the switch and
                      // dashboard while keeping their value — invalidating would
                      // blank them and flicker.
                    },
                  ),
                  () => const SizedBox.shrink(),
                ),
                const _AppLockTile(),
              ],
            )),
        const SizedBox(height: AppSpacing.s3),
        PremiumMotion(
            delay: const Duration(milliseconds: 120),
            child: _Section(
              title: 'الحساب',
              children: [
                _NavTile(
                  icon: AppLucideIcons.repeat,
                  title: 'ابدأ من جديد',
                  subtitle: 'امسح البيانات المحلية مع إبقاء الحساب نشطًا',
                  onTap: () => _confirmReset(context, ref),
                ),
                _NavTile(
                  icon: AppLucideIcons.logOut,
                  iconColor: c.danger,
                  title: 'تسجيل الخروج',
                  onTap: () => _signOut(context, ref),
                ),
                _NavTile(
                  icon: AppLucideIcons.trash2,
                  iconColor: c.danger,
                  title: 'حذف الحساب وكل بياناتي',
                  subtitle: 'إجراء نهائي يتطلب تأكيدك',
                  onTap: () => context.push('/privacy'),
                ),
              ],
            )),
        // Debug-only entry point into the Mali design-system review surface
        // (docs/MALI_DESIGN_SYSTEM.md). The route itself is also gated by
        // kDebugMode in app_router.dart, so this tile is redundant defense,
        // not the only gate — it simply doesn't exist in release builds.
        if (kDebugMode) ...[
          const SizedBox(height: AppSpacing.s3),
          PremiumMotion(
              delay: const Duration(milliseconds: 140),
              child: _Section(
                title: 'Developer',
                children: [
                  _NavTile(
                    icon: AppLucideIcons.shapes,
                    title: 'Design Gallery',
                    subtitle: 'Qirsh flagship design system — debug only',
                    onTap: () => context.push('/design'),
                  ),
                ],
              )),
        ],
      ],
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

  Future<void> _sendTestNotification(BuildContext context) async {
    final sent = await LocalNotificationService.instance.showTestNotification();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          sent
              ? 'أرسلنا إشعاراً تجريبياً من قرش.'
              : 'تعذّر إرسال الإشعار التجريبي.',
        ),
      ),
    );
  }

  /// يمسح بيانات هذا المستخدم محلياً أولاً (عبر AppSession.signOut، والذي
  /// يفشل بالكامل بدل الاستمرار صامتاً إن تعذّر المسح) قبل إنهاء الجلسة على
  /// خادم Supabase — بهذا الترتيب فقط: فشل المسح المحلي لا يترك الجهاز بلا
  /// جلسة بعيدة بينما تبقى بياناته المالية قابلة للقراءة لمن يسجّل دخوله بعده.
  Future<void> _signOut(BuildContext context, WidgetRef ref) async {
    // MALI-053n/011/017: sign-out wipes local data, so unsynced/local-only user
    // data (pending ledger/planning/child outboxes, smart-inbox status, and
    // cloud-unsupported local-only cards) must never be destroyed silently.
    // Take a full pre-wipe inventory; if anything is pending, attempt a bounded
    // flush, then RE-CHECK (a timeout is NOT success); only what still remains
    // is offered for explicit discard, and the user can always cancel.
    try {
      final inventory = ref.read(unsyncedInventoryServiceProvider);
      var pending = await inventory.collect();
      if (pending.hasPendingUserData) {
        await AppSession.instance.flushPendingForSignOut();
        pending = await inventory.collect(); // re-check after the flush
      }
      if (pending.hasPendingUserData && context.mounted) {
        final proceed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('بيانات غير محفوظة سحابيًا'),
            content: Text(_unsyncedSignOutMessage(pending)),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('إلغاء'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('تسجيل الخروج وحذف غير المحفوظ'),
              ),
            ],
          ),
        );
        if (proceed != true) return; // cancel → abort sign-out, nothing wiped
      }
    } catch (_) {
      // A detection failure must never trap the user in the app — but it also
      // must not silently wipe. Surface it and abort so the user can retry.
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content:
                Text('تعذّر التحقق من البيانات غير المحفوظة. حاول مجدداً.'),
          ),
        );
      }
      return;
    }
    try {
      await AppSession.instance.signOut();
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تعذّر تسجيل الخروج بأمان. حاول مجدداً.'),
          ),
        );
      }
      return;
    }
    try {
      await ref.read(authServiceProvider).signOutProviderSession();
    } catch (_) {
      // The local wipe is already authoritative. A provider logout failure
      // must not restore access to the previous user's local financial data.
    }
    if (SupabaseConfig.isConfigured) {
      try {
        await supabase.Supabase.instance.client.auth.signOut();
      } catch (_) {
        // Local wipe/sign-out above already protects the device even if the
        // network sign-out fails.
      }
    }
  }

  Map<String, String> _countryValues(List<RemoteCountry> countries) {
    return {
      for (final country in countries)
        country.code.toUpperCase():
            '${country.flagEmoji} ${country.nameAr} · ${country.phonePrefix}',
    };
  }

  Map<String, String> _currencyValuesForCountry(
    String country,
    List<RemoteCurrency> currencies,
  ) {
    final normalizedCountry = country.trim().toUpperCase();
    final scoped = currencies
        .where((currency) => currency.countryCodes.contains(normalizedCountry))
        .toList(growable: false);
    final source = scoped.isEmpty ? currencies : scoped;
    return {
      for (final currency in source)
        currency.code.toUpperCase():
            '${currency.code.toUpperCase()} · ${currency.nameAr} · ${currency.symbol}',
    };
  }

  String _preferredCurrencyForCountry(
    String country,
    List<RemoteCurrency> currencies,
    String current,
  ) {
    final normalizedCountry = country.trim().toUpperCase();
    final normalizedCurrent = current.trim().toUpperCase();
    final countryCurrencies = currencies
        .where((currency) => currency.countryCodes.contains(normalizedCountry))
        .toList(growable: false);
    if (countryCurrencies.any(
      (currency) => currency.code.toUpperCase() == normalizedCurrent,
    )) {
      return normalizedCurrent;
    }
    if (countryCurrencies.isNotEmpty) {
      return countryCurrencies.first.code.toUpperCase();
    }
    return normalizedCurrent;
  }

  Future<void> _pickProfileImage(
    BuildContext context,
    WidgetRef ref,
    UserSettingsEntity settings,
  ) async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1200,
      imageQuality: 86,
    );
    if (picked == null) return;
    final directory = await getApplicationDocumentsDirectory();
    final extension = p.extension(picked.path).isEmpty
        ? '.jpg'
        : p.extension(picked.path).toLowerCase();
    final avatarsDir = Directory(p.join(directory.path, 'profile'));
    if (!await avatarsDir.exists()) {
      await avatarsDir.create(recursive: true);
    }
    final destination = File(
      p.join(avatarsDir.path, 'avatar$extension'),
    );
    await File(picked.path).copy(destination.path);
    await ref.read(userSettingsRepositoryProvider).saveSettings(
          settings.copyWith(avatarPath: destination.path),
        );
    _refreshSettingsDependents(ref);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('تم تحديث الصورة.')),
    );
  }

  Future<void> _showProfileTextSheet(
    BuildContext context,
    WidgetRef ref, {
    required String title,
    required String label,
    required String initialValue,
    required UserSettingsEntity Function(String value) apply,
    TextInputType keyboardType = TextInputType.text,
  }) async {
    final c = context.colors;
    final controller = TextEditingController(text: initialValue);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => navySheetTheme(Directionality(
        textDirection: TextDirection.rtl,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            AppSpacing.s2,
            AppSpacing.gutter,
            MediaQuery.of(context).viewInsets.bottom + AppSpacing.s6,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: AppTypography.sectionTitle(c.textMain)),
              const SizedBox(height: AppSpacing.s3),
              TextField(
                controller: controller,
                autofocus: true,
                keyboardType: keyboardType,
                decoration: InputDecoration(
                  labelText: label,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.s3),
              SizedBox(
                height: AppSpacing.buttonHeight,
                child: FilledButton(
                  onPressed: () async {
                    await ref
                        .read(userSettingsRepositoryProvider)
                        .saveSettings(apply(controller.text));
                    _refreshSettingsDependents(ref);
                    if (context.mounted) Navigator.of(context).pop();
                  },
                  child: const Text('حفظ'),
                ),
              ),
            ],
          ),
        ),
      )),
    );
    // Do NOT dispose controller here – the sheet's exit animation may still
    // reference it.  Because it is a local variable, it will be GC'd once
    // the animation completes and all listeners are released.
  }

  void _refreshSettingsDependents(WidgetRef ref) {
    refreshUserSettings(ref);
    ref.invalidate(baseCurrencyProvider);
    ref.invalidate(accountsProvider);
    ref.invalidate(dashboardDataProvider);
  }

  Future<void> _showSettingsPicker(
    BuildContext context,
    WidgetRef ref, {
    required String title,
    required String current,
    required Map<String, String> values,
    UserSettingsEntity Function(String value)? apply,
    Future<void> Function(String value)? save,
  }) {
    final c = context.colors;
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => navySheetTheme(Directionality(
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
            Text(title, style: AppTypography.sectionTitle(c.textMain)),
            const SizedBox(height: AppSpacing.s3),
            for (final entry in values.entries)
              RadioListTile<String>(
                value: entry.key,
                groupValue: current,
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
                  if (save != null) {
                    await save(value);
                  } else if (apply != null) {
                    await ref
                        .read(userSettingsRepositoryProvider)
                        .saveSettings(apply(value));
                  }
                  _refreshSettingsDependents(ref);
                  if (context.mounted) Navigator.of(context).pop();
                },
              ),
          ],
        ),
      )),
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
      builder: (context) => navySheetTheme(Directionality(
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
              Text('التصنيفات', style: AppTypography.sectionTitle(c.textMain)),
              Text(
                'أضف أو عدّل التصنيفات التي تظهر في العمليات والتقارير.',
                style: AppTypography.callout(c.textLight),
              ),
              const SizedBox(height: AppSpacing.s3),
              FilledButton.icon(
                onPressed: () => _showCategoryForm(context, ref),
                icon: const Icon(AppLucideIcons.plus),
                label: const Text('إضافة تصنيف'),
              ),
              const SizedBox(height: AppSpacing.s3),
              _CategoryGroup(
                title: 'مصروفات',
                items: expenses,
                onEdit: (item) => _showCategoryForm(context, ref, item: item),
                onDelete: (item) => _deleteCategory(context, ref, item),
              ),
              const SizedBox(height: AppSpacing.s3),
              _CategoryGroup(
                title: 'دخل',
                items: income,
                onEdit: (item) => _showCategoryForm(context, ref, item: item),
                onDelete: (item) => _deleteCategory(context, ref, item),
              ),
              const SizedBox(height: AppSpacing.s3),
              _CategoryGroup(
                title: 'تحويلات',
                items: transfers,
                onEdit: (item) => _showCategoryForm(context, ref, item: item),
                onDelete: (item) => _deleteCategory(context, ref, item),
              ),
            ],
          ),
        ),
      )),
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
      builder: (context) => navySheetTheme(StatefulBuilder(
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
              children: [
                Text(
                  isEditing ? 'تعديل تصنيف' : 'إضافة تصنيف',
                  style: AppTypography.sectionTitle(c.textMain),
                ),
                const SizedBox(height: AppSpacing.s3),
                TextField(
                  controller: name,
                  decoration: const InputDecoration(
                    labelText: 'اسم التصنيف',
                    prefixIcon: Icon(AppLucideIcons.tag),
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
                    prefixIcon: Icon(AppLucideIcons.smile),
                  ),
                  items: icons
                      .map(
                        (value) => DropdownMenuItem(
                          value: value,
                          child: Row(
                            children: [
                              CategoryGlyph(
                                  name: value, size: 18, color: c.textMain),
                              const SizedBox(width: 8),
                              Text(value),
                            ],
                          ),
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
                    prefixIcon: Icon(AppLucideIcons.palette),
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
                const SizedBox(height: AppSpacing.s3),
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
      )),
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
      builder: (context) => navySheetTheme(StatefulBuilder(
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
                Text('ساعات الهدوء',
                    style: AppTypography.sectionTitle(c.textMain)),
                const SizedBox(height: AppSpacing.s2),
                Text(
                  'نؤجل الإشعارات المجدولة خلال هذه الفترة لأول وقت مسموح.',
                  style: AppTypography.callout(c.textLight),
                ),
                const SizedBox(height: AppSpacing.s3),
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
                const SizedBox(height: AppSpacing.s3),
                SizedBox(
                  height: AppSpacing.buttonHeight,
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
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    child: Text(
                      'حفظ',
                      style: AppTypography.bodyStrong(c.onInk),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      )),
    );
  }

  Future<void> _copyInviteText(BuildContext context) async {
    await Clipboard.setData(
      const ClipboardData(
        text:
            'جرّب قرش: تطبيق عربي يساعدك تفهم مصروفاتك من رسائل البنك وتتابع ميزانيتك بسهولة.',
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
          'قرش لتتبع المصروفات من رسائل البنك والإدخال اليدوي. يمكنك نقل بياناتك المالية كملفات CSV أو حزمة ZIP من قسم البيانات والخصوصية.',
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
      builder: (context) => navySheetTheme(Directionality(
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
              Text(title, style: AppTypography.sectionTitle(c.textMain)),
              const SizedBox(height: AppSpacing.s2),
              Text(body, style: AppTypography.callout(c.textLight)),
              const SizedBox(height: AppSpacing.s3),
              SizedBox(
                height: AppSpacing.buttonHeight,
                child: FilledButton(
                  onPressed: () async {
                    await onAction?.call();
                    if (context.mounted) Navigator.of(context).pop();
                  },
                  style: FilledButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: Text(
                    actionLabel,
                    style: AppTypography.bodyStrong(c.onInk),
                  ),
                ),
              ),
            ],
          ),
        ),
      )),
    );
  }

  Future<void> _confirmReset(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('مسح جميع البيانات؟'),
        content: const Text('سيتم مسح جميع بياناتك المحلية. لا يمكن التراجع.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('مسح'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(dataWipeServiceProvider).wipeAll();
    await AppSession.instance.wipeAndReset();
    if (context.mounted) context.go('/welcome');
  }
}

class _SettingsLoadingState extends StatelessWidget {
  const _SettingsLoadingState();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      height: 140,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: c.border),
      ),
      child: const CircularProgressIndicator(),
    );
  }
}

class _SettingsErrorState extends StatelessWidget {
  const _SettingsErrorState();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s5),
      decoration: BoxDecoration(
        color: c.dangerBg,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: c.danger.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(AppLucideIcons.alertCircle, color: c.danger),
          const SizedBox(width: AppSpacing.s3),
          Expanded(
            child: Text(
              'تعذر تحميل الإعدادات. حاول مرة أخرى بعد قليل.',
              style: AppTypography.body(c.textMain),
            ),
          ),
        ],
      ),
    );
  }
}

/// Blue profile hero for Settings — title + avatar/name/contact/edit on the
/// gradient, then the rounded page-bg lip (same language as CalmPageHeader).
class _SettingsHeader extends StatelessWidget {
  const _SettingsHeader({
    required this.name,
    required this.contact,
    required this.avatarPath,
    this.onBack,
    this.onAvatarTap,
    this.onNameTap,
  });

  final String name;
  final String contact;
  final String avatarPath;
  final VoidCallback? onBack;
  final VoidCallback? onAvatarTap;
  final VoidCallback? onNameTap;

  @override
  Widget build(BuildContext context) {
    final file = avatarPath.isEmpty ? null : File(avatarPath);
    final hasImage = file != null && file.existsSync();
    final initial = name.trim().isEmpty ? 'م' : name.characters.first;
    // نفس هيدر باقي الصفحات (CalmPageHeader بميلته الموحّد) — صف البروفايل
    // جوّه الأزرق عبر خانة child.
    return CalmPageHeader(
      // شرائح متعددة: الأزرق ميمتدّش تحت (هيغطّي المحتوى) — الذوبان جوّه.
      meltOverflow: 0,
      title: 'الإعدادات',
      leading: onBack == null
          ? null
          : IconButton(
              tooltip: 'رجوع',
              onPressed: onBack,
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(),
              icon: const Icon(AppLucideIcons.arrowRight, color: Colors.white),
            ),
      child: Row(
        children: [
          GestureDetector(
            onTap: onAvatarTap,
            child: Container(
              width: 58,
              height: 58,
              alignment: Alignment.center,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(19),
              ),
              child: hasImage
                  ? Image.file(file, fit: BoxFit.cover, width: 58, height: 58)
                  : Text(initial, style: AppTypography.title2(Colors.white)),
            ),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: GestureDetector(
              onTap: onNameTap,
              behavior: HitTestBehavior.opaque,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.headline(Colors.white)),
                  const SizedBox(height: 2),
                  Text(contact,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textDirection: TextDirection.ltr,
                      style: AppTypography.caption(
                          Colors.white.withValues(alpha: 0.75))),
                ],
              ),
            ),
          ),
          GestureDetector(
            onTap: onNameTap,
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.16),
                border: Border.all(color: Colors.white.withValues(alpha: 0.28)),
              ),
              child: const Icon(AppLucideIcons.pencil,
                  color: Colors.white, size: 18),
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.children,
    this.description,
  });

  final String title;
  final String? description;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.s2, 0, AppSpacing.s2, AppSpacing.s1),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: AppTypography.footnote(c.textLight)
                    .copyWith(fontWeight: FontWeight.w700),
              ),
              if (description != null) ...[
                const SizedBox(height: 1),
                Text(
                  description!,
                  style: AppTypography.micro(c.textMuted),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.s2),
        Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: c.surfaceCard,
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(color: c.border),
            boxShadow: AppShadows.card,
          ),
          child: Material(
            color: Colors.transparent,
            child: Column(
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  children[i],
                  if (i != children.length - 1)
                    Divider(
                      height: 1,
                      indent: AppSpacing.s4,
                      endIndent: AppSpacing.s4,
                      color: c.divider,
                    ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ThemeModeSelector extends StatelessWidget {
  const _ThemeModeSelector({required this.value, required this.onChanged});

  final ThemeMode value;
  final ValueChanged<ThemeMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    const options = <(ThemeMode, IconData, String)>[
      (ThemeMode.system, AppLucideIcons.monitor, 'تلقائي'),
      (ThemeMode.light, AppLucideIcons.sun, 'فاتح'),
      (ThemeMode.dark, AppLucideIcons.moon, 'داكن'),
    ];
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.s3),
      child: Row(
        children: [
          for (final (mode, icon, label) in options) ...[
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onChanged(mode),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.s3),
                  // المختار = سطح ink الموحّد (كان أزرق ctaSoft).
                  decoration: BoxDecoration(
                    color: value == mode ? c.ink : c.surfaceMuted,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    border: value == mode ? null : Border.all(color: c.border),
                  ),
                  child: Column(
                    children: [
                      Icon(
                        icon,
                        size: 20,
                        color: value == mode ? c.onInk : c.textSecondary,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        label,
                        style: AppTypography.caption(
                          value == mode ? c.onInk : c.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (mode != ThemeMode.dark) const SizedBox(width: AppSpacing.s3),
          ],
        ],
      ),
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
        Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(AppRadius.card),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            child: Column(
              children: [
                for (var i = 0; i < items.length; i++) ...[
                  ListTile(
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: AppSpacing.s4),
                    leading: CircleAvatar(
                      backgroundColor: items[i].color.withValues(alpha: 0.12),
                      child:
                          Icon(items[i].icon, color: items[i].color, size: 18),
                    ),
                    title: Text(items[i].nameAr),
                    subtitle: Text(items[i].key),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'تعديل',
                          onPressed: () => onEdit(items[i]),
                          icon: const Icon(AppLucideIcons.pencil),
                        ),
                        if (items[i].entity.sort >= 0)
                          IconButton(
                            tooltip: 'حذف',
                            onPressed: () => onDelete(items[i]),
                            icon: Icon(AppLucideIcons.trash2, color: c.danger),
                          ),
                      ],
                    ),
                  ),
                  if (i != items.length - 1)
                    Divider(height: 1, color: c.border),
                ],
              ],
            ),
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
      icon: AppLucideIcons.lock,
      iconColor: c.primary,
      value: _enabled,
      onChanged: _loading || _busy ? (_) {} : _setEnabled,
    );
  }
}

class _NavTile extends StatelessWidget {
  const _NavTile({
    required this.icon,
    required this.title,
    this.subtitle,
    this.iconColor,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Color? iconColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ListTile(
      visualDensity: VisualDensity.compact,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: AppSpacing.s4, vertical: 2),
      minVerticalPadding: AppSpacing.s2,
      leading: _TileIcon(icon: icon, color: iconColor ?? c.primary),
      title: Text(title, style: AppTypography.subhead(c.textMain)),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.caption(c.textLight),
            ),
      trailing: Icon(AppLucideIcons.chevronLeft, color: c.textMuted, size: 20),
      onTap: onTap,
    );
  }
}

class _TrustNoticeTile extends StatelessWidget {
  const _TrustNoticeTile({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s4,
        vertical: AppSpacing.s3,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _TileIcon(icon: AppLucideIcons.shieldCheck, color: c.success),
          const SizedBox(width: AppSpacing.s3),
          Expanded(
            child: Text(
              text,
              style: AppTypography.caption(c.textLight).copyWith(height: 1.45),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

class _CaptureHealthTile extends StatelessWidget {
  const _CaptureHealthTile({required this.status});

  final CaptureHealthStatus status;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final subtitle = status.lastCaptureAt == null
        ? 'لم نرصد أي رسالة بنكية بعد'
        : 'آخر عملية رصد: ${_captureGapLabel(status.gap!)}';
    final apnsFailure = status.apnsRegistrationFailure;
    final color = status.shouldNudge ? c.accent : c.success;
    final title = apnsFailure != null
        ? 'تعذّر تفعيل إشعارات رصد البنك'
        : status.shouldNudge
            ? 'لم نستقبل رسائل بنكية منذ فترة'
            : 'حالة رصد رسائل البنك';
    final statusSubtitle = apnsFailure != null
        ? 'فشل تسجيل APNs: ${apnsFailure.message}'
        : status.shouldNudge
            ? '$subtitle — تأكد أن الاختصار لا يزال مفعّلاً'
            : subtitle;
    final Widget? trailing = status.shouldNudge
        ? TextButton(
            onPressed:
                Platform.isIOS ? () => showIosShortcutSheet(context) : null,
            child: const Text('تحقق'),
          )
        : null;
    return ListTile(
      contentPadding:
          const EdgeInsets.symmetric(horizontal: AppSpacing.s4, vertical: 2),
      leading: _TileIcon(icon: AppLucideIcons.shieldCheck, color: color),
      title: Text(title, style: AppTypography.bodyStrong(c.textMain)),
      subtitle: Text(
        statusSubtitle,
        style: AppTypography.caption(c.textLight),
      ),
      trailing: trailing,
    );
  }
}

/// MALI-053n: precise "what will be lost" text for the sign-out discard dialog.
String _unsyncedSignOutMessage(UnsyncedInventory inv) {
  final parts = <String>[];
  if (inv.ledgerOutbox > 0) {
    parts.add('${inv.ledgerOutbox} تغيير في المعاملات');
  }
  if (inv.planningOutbox > 0) {
    parts.add(
      '${inv.planningOutbox} تغيير في الحسابات/الميزانيات/الأهداف/الفواتير',
    );
  }
  if (inv.smartInboxPending > 0) {
    parts.add('${inv.smartInboxPending} عنصر في صندوق الوارد');
  }
  if (inv.localOnlyCards > 0) {
    parts.add('${inv.localOnlyCards} بطاقة محفوظة على هذا الجهاز فقط');
  }
  final list = parts.join('، ');
  return 'لديك بيانات لم تُرفع للسحابة وسيحذفها تسجيل الخروج: $list. '
      'خُذ نسخة احتياطية أولًا إن أردت الاحتفاظ بها.';
}

String _captureGapLabel(Duration gap) {
  if (gap.inDays >= 1) {
    return 'منذ ${gap.inDays} ${gap.inDays == 1 ? 'يوم' : 'أيام'}';
  }
  if (gap.inHours >= 1) {
    return 'منذ ${gap.inHours} ${gap.inHours == 1 ? 'ساعة' : 'ساعات'}';
  }
  return 'اليوم';
}

class _SwitchTile extends StatelessWidget {
  const _SwitchTile({
    required this.title,
    required this.icon,
    this.iconColor,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final IconData icon;
  final Color? iconColor;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SwitchListTile(
      visualDensity: VisualDensity.compact,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: AppSpacing.s4, vertical: 2),
      minVerticalPadding: AppSpacing.s2,
      secondary: _TileIcon(icon: icon, color: iconColor ?? c.primary),
      value: value,
      onChanged: onChanged,
      activeThumbColor: c.onCta,
      activeTrackColor: c.cta,
      title: Text(title, style: AppTypography.subhead(c.textMain)),
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
    // نفس تايل [AppAvatar] بالظبط — سوبر-إليبس ولون تقيل وجليف أبيض.
    return AppAvatar.icon(
      icon: icon,
      color: Color.lerp(color, Colors.black, 0.45),
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
