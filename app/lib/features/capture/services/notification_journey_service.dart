import 'package:drift/drift.dart';

import '../../../core/i18n/bilingual_copy.dart';
import '../../../data/catalog/catalog_daos.dart';
import '../../../data/db/app_database.dart';
import '../../../data/repositories/drift_user_settings_repository.dart';
import '../../../domain/entities/engagement_entities.dart';
import '../../../domain/usecases/user_settings_usecases.dart';
import 'local_notification_service.dart';

class NotificationJourneyService {
  NotificationJourneyService({
    required AppDatabase database,
    required LoadNotificationPreferencesUseCase loadPreferences,
    required SaveNotificationPreferencesUseCase savePreferences,
    RemoteGrowthCampaignsDao? campaignsDao,
    LocalNotificationService? localNotifications,
    DateTime Function()? now,
  })  : _database = database,
        _loadPreferences = loadPreferences,
        _savePreferences = savePreferences,
        _campaignsDao = campaignsDao,
        _localNotifications =
            localNotifications ?? LocalNotificationService.instance,
        _now = now ?? (() => DateTime.now().toUtc());

  static const Duration marketingCooldown = Duration(hours: 24);
  static const Duration shortcutReminderDelay = Duration(hours: 6);

  final AppDatabase _database;
  final LoadNotificationPreferencesUseCase _loadPreferences;
  final SaveNotificationPreferencesUseCase _savePreferences;
  final RemoteGrowthCampaignsDao? _campaignsDao;
  final LocalNotificationService _localNotifications;
  final DateTime Function() _now;

  Future<void> evaluate() async {
    var preferences = await _loadPreferences();
    final now = _now().toUtc();
    var inbox = preferences.inboxState;
    if (inbox.firstSeenAt == null) {
      inbox = inbox.copyWith(firstSeenAt: now);
      preferences = preferences.copyWith(inboxState: inbox);
      await _savePreferences(preferences);
    }

    final profile = await _readProfile();
    // `user_settings.language` — the same row `localeProvider` reads, so a
    // notification speaks the language the app is actually in. Read here, in
    // the service that already holds the database, rather than pulled from a
    // widget: this code runs with no element tree and must not depend on one.
    final lang =
        (await DriftUserSettingsRepository(_database).getSettings()).language;
    // The Android channel NAME follows the same language as the copy. The two
    // are set from one value here so a notification cannot arrive in English
    // inside a channel called «رسائل ونصائح قرش» — `_channel` and the channel
    // copy read this field, and `evaluateAfterCapture` can run before anything
    // in the widget tree has pushed it.
    _localNotifications.notificationLanguage = lang;
    final candidates = _journeysFor(profile, preferences.inboxState, now);
    for (final journey in candidates) {
      preferences = await _loadPreferences();
      final decision = _canSendMarketing(journey.id, preferences, now);
      if (!decision.allowed) {
        continue;
      }
      await _localNotifications.showMarketingNotification(
        id: journey.notificationId,
        title: journey.titleIn(lang),
        body: journey.bodyIn(lang),
        preferences: preferences,
        route: journey.route,
      );
      final updatedInbox =
          preferences.inboxState.markJourneySent(journey.id, now).addHistory(
                NotificationHistoryEntry(
                  id: journey.id,
                  kind: 'journey',
                  title: journey.titleIn(lang),
                  body: journey.bodyIn(lang),
                  route: journey.route,
                  sentAt: now,
                ),
              );
      await _savePreferences(preferences.copyWith(inboxState: updatedInbox));
      break;
    }
    await _evaluateRemoteNotificationCampaign(profile, now, lang);
  }

  Future<void> evaluateAfterCapture() => evaluate();

  Future<void> _evaluateRemoteNotificationCampaign(
    _NotificationProfile profile,
    DateTime now,
    String lang,
  ) async {
    final campaignsDao = _campaignsDao;
    if (campaignsDao == null) return;
    final campaigns = await campaignsDao.getActiveByType('notification');
    if (campaigns.isEmpty) return;
    for (final campaign in campaigns) {
      var preferences = await _loadPreferences();
      if (!_matchesSegment(campaign.targetSegment, profile)) continue;
      final inbox = preferences.inboxState;
      if (inbox.hasDismissed(campaign.id)) continue;
      if (campaign.oncePerUser && inbox.impressionsFor(campaign.id) > 0) {
        continue;
      }
      final max = campaign.maxImpressions;
      if (max != null && inbox.impressionsFor(campaign.id) >= max) {
        continue;
      }
      final lastSent = inbox.lastSentFor(campaign.id);
      if (lastSent != null &&
          now.difference(lastSent).inHours < campaign.cooldownHours) {
        continue;
      }
      final decision = _canSendMarketing(campaign.id, preferences, now);
      if (!decision.allowed) continue;
      // Server-authored copy in the user's language. `titleIn`/`bodyIn` carry
      // the same fallback the banners use — an empty English field falls back
      // to Arabic rather than sending a blank notification.
      final title = campaign.titleIn(lang);
      final body = campaign.bodyIn(lang)?.trim();
      final resolvedBody = body?.isNotEmpty == true ? body! : title;
      await _localNotifications.showMarketingNotification(
        // 31-bit-safe: a raw hashCode > 2^31 is dropped by the Android plugin.
        id: campaign.id.hashCode & 0x7FFFFFFF,
        title: title,
        body: resolvedBody,
        preferences: preferences,
        route: campaign.actionRoute?.trim().isNotEmpty == true
            ? campaign.actionRoute!.trim()
            : '/dashboard',
      );
      preferences = await _loadPreferences();
      final updatedInbox = preferences.inboxState
          .markMarketingSent(campaign.id, now)
          .markImpression(campaign.id)
          .addHistory(
            NotificationHistoryEntry(
              // The in-app record of what was sent. It keeps the real copy
              // even when the OS banner was redacted, so it has to be in the
              // reader's language too — this is the surface they open to find
              // out what the notification said.
              id: campaign.id,
              kind: 'campaign',
              title: title,
              body: resolvedBody,
              route: campaign.actionRoute,
              sentAt: now,
            ),
          );
      await _savePreferences(preferences.copyWith(inboxState: updatedInbox));
      break;
    }
  }

  List<_JourneyCandidate> _journeysFor(
    _NotificationProfile profile,
    NotificationInboxState inbox,
    DateTime now,
  ) {
    final firstSeenAt = inbox.firstSeenAt ?? now;
    return [
      if (!inbox.hasSentJourney('welcome'))
        const _JourneyCandidate(
          id: 'welcome',
          notificationId: 94001,
          title: 'أهلًا بك في قِرش',
          body: 'لنجهّز التقاط رسائل البنك ونبدأ ترتيب مصاريفك تلقائيًا.',
          titleEn: 'Welcome to Qirsh',
          bodyEn: 'Let us set up bank-message capture and start sorting your '
              'spending automatically.',
          route: '/settings',
        ),
      if (profile.transactionCount == 0 &&
          now.difference(firstSeenAt) >= shortcutReminderDelay &&
          !inbox.hasSentJourney('shortcut_reminder'))
        const _JourneyCandidate(
          id: 'shortcut_reminder',
          notificationId: 94002,
          title: 'خطوة واحدة ويبدأ قِرش العمل',
          body: 'اربط اختصار الرسائل لتسجيل مصاريفك دون إدخال يدوي.',
          titleEn: 'One step and Qirsh starts working',
          bodyEn: 'Connect the Messages shortcut to record your spending '
              'without typing it in.',
          route: '/settings',
        ),
      if (profile.transactionCount >= 1 &&
          !inbox.hasSentJourney('first_transaction'))
        const _JourneyCandidate(
          id: 'first_transaction',
          notificationId: 94003,
          title: 'سُجّلت أول عملية',
          body: 'بدأ قِرش يفهم نمط مصاريفك. راجع التصنيف لجعله أدق.',
          titleEn: 'Your first transaction is in',
          bodyEn: 'Qirsh is starting to learn how you spend. Check the category '
              'to make it sharper.',
          route: '/transactions',
        ),
      if (profile.transactionCount >= 3 &&
          !inbox.hasSentJourney('three_transactions'))
        const _JourneyCandidate(
          id: 'three_transactions',
          notificationId: 94004,
          title: 'بدأت الصورة تتّضح',
          body: 'افتح لوحة التحكم واطّلع على أول قراءة حقيقية لمصاريفك.',
          titleEn: 'The picture is taking shape',
          bodyEn: 'Open the dashboard for the first real read on your '
              'spending.',
          route: '/dashboard',
        ),
      if (profile.transactionCount > 0 &&
          now.difference(firstSeenAt) >= const Duration(days: 7) &&
          !inbox.hasSentJourney('first_week_summary'))
        const _JourneyCandidate(
          id: 'first_week_summary',
          notificationId: 94005,
          title: 'ملخصك الأول جاهز',
          body: 'اطّلع على أكثر تصنيف استهلك ميزانيتك هذا الأسبوع.',
          titleEn: 'Your first summary is ready',
          bodyEn: 'See which category took the most of your budget this '
              'week.',
          route: '/reports',
        ),
    ];
  }

  _MarketingDecision _canSendMarketing(
    String id,
    NotificationPreferences preferences,
    DateTime now,
  ) {
    if (!preferences.marketingMessages) {
      return const _MarketingDecision(false);
    }
    final inbox = preferences.inboxState;
    if (inbox.hasDismissed(id) || inbox.hasSentJourney(id)) {
      return const _MarketingDecision(false);
    }
    final lastMarketing = inbox.lastMarketingNotificationAt;
    if (lastMarketing != null &&
        now.difference(lastMarketing) < marketingCooldown) {
      return const _MarketingDecision(false);
    }
    return const _MarketingDecision(true);
  }

  bool _matchesSegment(String segment, _NotificationProfile profile) {
    switch (segment) {
      case 'all':
        return true;
      case 'new_user':
      case 'no_shortcut':
        return profile.transactionCount == 0;
      case 'has_first_transaction':
        return profile.transactionCount >= 1;
      case 'inactive_3_days':
        final last = profile.lastTransactionAt;
        return last != null && _now().difference(last).inDays >= 3;
      case 'active_user':
        final last = profile.lastTransactionAt;
        return last != null && _now().difference(last).inDays < 3;
      case 'budget_user':
        return profile.budgetCount > 0;
      default:
        return true;
    }
  }

  Future<_NotificationProfile> _readProfile() async {
    final rows = await _database.customSelect(
      '''
        SELECT
          COUNT(*) AS transaction_count,
          MAX(created_at) AS last_transaction_at
        FROM transactions
        WHERE status != ?;
      ''',
      variables: [Variable.withString('ignored')],
    ).getSingle();
    final budgetRows = await _database
        .customSelect('SELECT COUNT(*) AS budget_count FROM budgets;')
        .getSingle();
    final lastRaw = rows.readNullable<String>('last_transaction_at');
    return _NotificationProfile(
      transactionCount: rows.read<int>('transaction_count'),
      budgetCount: budgetRows.read<int>('budget_count'),
      lastTransactionAt:
          lastRaw == null ? null : DateTime.tryParse(lastRaw)?.toUtc(),
    );
  }
}

class _NotificationProfile {
  const _NotificationProfile({
    required this.transactionCount,
    required this.budgetCount,
    required this.lastTransactionAt,
  });

  final int transactionCount;
  final int budgetCount;
  final DateTime? lastTransactionAt;
}

class _JourneyCandidate {
  const _JourneyCandidate({
    required this.id,
    required this.notificationId,
    required this.title,
    required this.body,
    required this.titleEn,
    required this.bodyEn,
    required this.route,
  });

  final String id;
  final int notificationId;
  final String title;
  final String body;
  final String titleEn;
  final String bodyEn;
  final String route;

  String titleIn(String languageCode) => languageCode == 'en' ? titleEn : title;
  String bodyIn(String languageCode) => languageCode == 'en' ? bodyEn : body;
}

class _MarketingDecision {
  const _MarketingDecision(this.allowed);

  final bool allowed;
}
