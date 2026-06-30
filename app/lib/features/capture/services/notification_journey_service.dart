import 'package:drift/drift.dart';

import '../../../data/catalog/catalog_daos.dart';
import '../../../data/db/app_database.dart';
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
    final candidates = _journeysFor(profile, preferences.inboxState, now);
    for (final journey in candidates) {
      preferences = await _loadPreferences();
      final decision = _canSendMarketing(journey.id, preferences, now);
      if (!decision.allowed) {
        continue;
      }
      await _localNotifications.showMarketingNotification(
        id: journey.notificationId,
        title: journey.title,
        body: journey.body,
        preferences: preferences,
        route: journey.route,
      );
      final updatedInbox =
          preferences.inboxState.markJourneySent(journey.id, now);
      await _savePreferences(preferences.copyWith(inboxState: updatedInbox));
      break;
    }
    await _evaluateRemoteNotificationCampaign(profile, now);
  }

  Future<void> evaluateAfterCapture() => evaluate();

  Future<void> _evaluateRemoteNotificationCampaign(
    _NotificationProfile profile,
    DateTime now,
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
      await _localNotifications.showMarketingNotification(
        id: campaign.id.hashCode,
        title: campaign.titleAr,
        body: campaign.bodyAr?.trim().isNotEmpty == true
            ? campaign.bodyAr!.trim()
            : campaign.titleAr,
        preferences: preferences,
        route: campaign.actionRoute?.trim().isNotEmpty == true
            ? campaign.actionRoute!.trim()
            : '/dashboard',
      );
      preferences = await _loadPreferences();
      final updatedInbox = preferences.inboxState
          .markMarketingSent(campaign.id, now)
          .markImpression(campaign.id);
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
          title: 'أهلاً بك في قرش',
          body: 'خلّينا نجهز التقاط رسائل البنك ونبدأ نرتب مصاريفك تلقائياً.',
          route: '/settings',
        ),
      if (profile.transactionCount == 0 &&
          now.difference(firstSeenAt) >= shortcutReminderDelay &&
          !inbox.hasSentJourney('shortcut_reminder'))
        const _JourneyCandidate(
          id: 'shortcut_reminder',
          notificationId: 94002,
          title: 'خطوة واحدة وقرش يبدأ يشتغل',
          body: 'اربط Shortcut الرسائل عشان نسجل مصاريفك بدون إدخال يدوي.',
          route: '/settings',
        ),
      if (profile.transactionCount >= 1 &&
          !inbox.hasSentJourney('first_transaction'))
        const _JourneyCandidate(
          id: 'first_transaction',
          notificationId: 94003,
          title: 'أول عملية اتسجلت',
          body: 'قرش بدأ يفهم نمط مصاريفك. راجع التصنيف وخليه أذكى.',
          route: '/transactions',
        ),
      if (profile.transactionCount >= 3 &&
          !inbox.hasSentJourney('three_transactions'))
        const _JourneyCandidate(
          id: 'three_transactions',
          notificationId: 94004,
          title: 'قرش بدأ يلتقط الصورة',
          body: 'افتح الداشبورد وشوف أول قراءة حقيقية لمصاريفك.',
          route: '/dashboard',
        ),
      if (profile.transactionCount > 0 &&
          now.difference(firstSeenAt) >= const Duration(days: 7) &&
          !inbox.hasSentJourney('first_week_summary'))
        const _JourneyCandidate(
          id: 'first_week_summary',
          notificationId: 94005,
          title: 'ملخصك الأول جاهز',
          body: 'شوف أكثر تصنيف سحب من ميزانيتك هذا الأسبوع.',
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
    required this.route,
  });

  final String id;
  final int notificationId;
  final String title;
  final String body;
  final String route;
}

class _MarketingDecision {
  const _MarketingDecision(this.allowed);

  final bool allowed;
}
