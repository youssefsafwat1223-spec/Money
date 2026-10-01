import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

import '../../../core/platform/device_timezone.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/ownership_guard.dart';
import '../../../data/db/planning_cutover.dart';
import '../../../data/repositories/drift_transaction_repository.dart';
import '../../../domain/entities/transaction_entity.dart';
import '../../planning_sync/services/outbox_queue_factory.dart';
import 'ledger_outbox_queue.dart';
import '../../../domain/entities/engagement_entities.dart';
import '../../../domain/services/notification_capacity_planner.dart';
import '../../../domain/services/notification_planner.dart';
import '../../app/capture_notification_actions.dart';
import '../capture_runtime.dart';
import 'notification_log_service.dart';
import 'pending_notification_actions.dart';

class CaptureNotificationPayload {
  const CaptureNotificationPayload({
    required this.kind,
    this.transactionId,
    this.route,
    this.notificationLogId,
    this.notificationType,
  });

  final String kind;
  final String? transactionId;
  final String? route;

  /// Phase 1 notification tracking fields (docs/NOTIFICATION_PIPELINE_AUDIT.md)
  /// — attached by [LocalNotificationService._show] right before handing the
  /// notification to the plugin, so a later tap can be correlated back to
  /// this exact attempt. [notificationType] here is the [NotificationType]
  /// enum name, unrelated to [kind] (which is only used for tap routing).
  final String? notificationLogId;
  final String? notificationType;

  String encode() => jsonEncode({
        'kind': kind,
        'transactionId': transactionId,
        'route': route,
        'notificationLogId': notificationLogId,
        'notificationType': notificationType,
      });

  static CaptureNotificationPayload? tryDecode(String? raw) {
    if (raw == null || raw.isEmpty) {
      return null;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      // Malformed JSON — treat as absent rather than throwing, so tap
      // routing and open-tracking degrade gracefully instead of leaving an
      // unhandled async exception (this runs unawaited from the plugin's
      // onDidReceiveNotificationResponse callback).
      return null;
    }
    if (decoded is! Map<String, dynamic>) {
      return null;
    }
    // Extract each field defensively — a single field with an unexpected
    // JSON type (e.g. notificationLogId stored as a number) must not
    // discard the rest of the payload and block tap navigation.
    return CaptureNotificationPayload(
      kind: _asString(decoded['kind']) ?? '',
      transactionId: _asString(decoded['transactionId']),
      route: _asString(decoded['route']),
      notificationLogId: _asString(decoded['notificationLogId']),
      notificationType: _asString(decoded['notificationType']),
    );
  }

  static String? _asString(Object? value) => value is String ? value : null;
}

// Action identifiers — مطابقة للـ iOS category actions.
const String _actionConfirm = 'confirm_tx';
const String _actionDismiss = 'dismiss_tx';
const String _reviewCategoryId = 'review_transaction';

class LocalNotificationService {
  LocalNotificationService._();

  static final LocalNotificationService instance = LocalNotificationService._();

  /// MALI-019 §6 — the redaction contract: generic, financial-data-free
  /// lock-screen content per type. Used by the local path; the APNs path honors
  /// the synced preference server-side (C6 coordination + edge policy). Public
  /// so the privacy guarantee is directly testable.
  static (String, String) redactedContentFor(NotificationType type,
      {String languageCode = 'ar'}) {
    // The brand name is the same in both — it is a name, not a word.
    const brand = 'قرش';
    const brandEn = 'Qirsh';
    final en = languageCode == 'en';
    final title = en ? brandEn : brand;
    switch (type) {
      case NotificationType.captureReview:
      case NotificationType.captureLight:
        return (
          title,
          en
              ? 'A transaction needs reviewing — open the app for details'
              : 'عملية بحاجة إلى مراجعة — افتح التطبيق لعرض التفاصيل'
        );
      case NotificationType.budgetWarning:
      case NotificationType.budgetOver:
        return (
          title,
          en ? 'You have a budget alert — open the app' : 'لديك تنبيه ميزانية — افتح التطبيق'
        );
      case NotificationType.subscriptionReminder:
        return (
          title,
          en ? 'You have a bill reminder — open the app' : 'لديك تذكير مالي — افتح التطبيق'
        );
      case NotificationType.goalMilestone:
        return (
          title,
          en ? 'You have a goal update — open the app' : 'لديك تحديث هدف — افتح التطبيق'
        );
      case NotificationType.weeklyReport:
        return (
          title,
          en ? 'Your weekly report is ready — open the app' : 'تقريرك الأسبوعي جاهز — افتح التطبيق'
        );
      case NotificationType.achievements:
        return (
          title,
          en ? 'You have a new achievement — open the app' : 'لديك إنجاز جديد — افتح التطبيق'
        );
      case NotificationType.dailyReminder:
        return (
          title,
          en ? 'Daily reminder — open the app' : 'تذكير يومي — افتح التطبيق'
        );
      case NotificationType.marketing:
        return (
          title,
          en ? 'You have a message — open the app' : 'لديك رسالة — افتح التطبيق'
        );
    }
  }

  /// The language notifications are emitted in.
  ///
  /// A notification is raised from background isolates and callbacks that have
  /// no element tree and often no repository handle, so the language is pushed
  /// in once rather than pulled at every emit site. Bootstrap sets it from
  /// settings and Settings updates it when the user switches language.
  /// Defaults to Arabic, which is what every caller got before this existed.
  String notificationLanguage = 'ar';

  /// ANDROID CHANNEL NAMING — why the ids below get a language suffix.
  ///
  /// Android stores a notification channel's NAME the first time the channel
  /// is created and keeps it for the lifetime of the install. Passing a
  /// different name with the same id is silently ignored, so a channel created
  /// in Arabic stays Arabic in the system Settings list forever, even for a
  /// user running the app in English. The ONLY way to change the name is a new
  /// channel id — or deleting the channel, which also discards every
  /// per-channel choice the user made (importance, sound, whether they muted
  /// it).
  ///
  /// So: the EXISTING ids keep their existing Arabic names and are now the
  /// Arabic channels, and English gets `<id>_en`. That choice is deliberate:
  ///
  ///  * Every existing install is Arabic. Nothing about it changes — same ids,
  ///    same names, and every mute/importance the user set is preserved. A
  ///    rename-by-deletion would have silently un-muted channels people
  ///    deliberately turned off.
  ///  * An English user gets English channel names from their first
  ///    notification.
  ///  * Switching language switches channel set. The other language's channels
  ///    stay behind rather than being deleted, so switching BACK restores the
  ///    user's settings for it. The cost is an unused entry in the system
  ///    Settings list; the alternative cost is losing their choices, which is
  ///    worse.
  ///
  /// [_channel] is the single place that applies the suffix. Every
  /// `AndroidNotificationDetails` goes through it, which is why none of them
  /// can be `const` any more.
  String _channel(String base) => notificationLanguage == 'en' ? '${base}_en' : base;

  /// A channel's name and description in the language it was created for.
  ({String name, String description}) _channelCopy(
    String arName,
    String arDescription,
    String enName,
    String enDescription,
  ) =>
      notificationLanguage == 'en'
          ? (name: enName, description: enDescription)
          : (name: arName, description: arDescription);

  static const String _reviewChannelId = 'capture_review';
  // v2 because Android keeps the original channel importance forever after it
  // is created. The old capture_light channel was low importance, so confirmed
  // captures could be saved without a visible banner.
  static const String _lightChannelId = 'capture_light_v2';
  static const String _marketingChannelId = 'qirsh_growth';
  static const String _budgetChannelId = 'budget_alerts';
  static const String _achievementChannelId = 'achievement_alerts';
  static const String _weeklyReportChannelId = 'weekly_reports';
  static const String _dailyReminderChannelId = 'daily_reminders';
  static const String _billReminderChannelId = 'bill_reminders';
  static const String _goalMilestoneChannelId = 'goal_milestones';
  /// RETIRED in V1 — the streak reminder was removed from the product. The id
  /// is kept so already-scheduled reminders on existing installs can still be
  /// found and cancelled; nothing schedules it any more.
  static const int retiredStreakReminderId = 88008;
  static const int _weeklyReportId = 91001;

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  /// MALI-025 — bounds how many pending reminders we keep, below iOS's ~64
  /// platform max, reserving headroom for immediate alerts.
  static const NotificationCapacityPlanner _capacityPlanner =
      NotificationCapacityPlanner();

  /// حافظة سجل الإشعارات داخل التطبيق (شاشة الرسائل). تُضبط عند الإقلاع
  /// بمستودع الإعدادات؛ كل إشعار يُعرض يُسجَّل هنا أيضاً حتى يجده المستخدم
  /// لاحقاً حتى لو فاتته الـ banner.
  Future<void> Function(NotificationHistoryEntry entry)? historyStore;

  /// Phase 1 notification tracking (docs/NOTIFICATION_PIPELINE_AUDIT.md) —
  /// set once at bootstrap (main.dart), same pattern as [historyStore]. Every
  /// call that shows/schedules a notification records created→sent/failed
  /// through this. Logging is always best-effort: a null [logService] (e.g.
  /// in a test that never wires it) or a logging failure must never prevent
  /// or delay the actual notification.
  NotificationLogService? logService;

  String get _localChannel => Platform.isIOS
      ? NotificationLogChannel.localIos
      : NotificationLogChannel.localAndroid;

  Future<String?> initialize() async {
    if (_initialized) {
      final details = await _plugin.getNotificationAppLaunchDetails();
      return _extractTransactionId(details?.notificationResponse?.payload);
    }

    tz.initializeTimeZones();
    await _configureLocalTimezone();

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    final darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
      notificationCategories: [
        DarwinNotificationCategory(
          _reviewCategoryId,
          actions: [
            DarwinNotificationAction.plain(
              _actionConfirm,
              'تأكيد ✓',
              // بدون foreground → يشتغل في الـ background بدون فتح التطبيق
            ),
            DarwinNotificationAction.plain(
              _actionDismiss,
              'تجاهل',
              options: {DarwinNotificationActionOption.destructive},
            ),
          ],
        ),
        // The plugin REPLACES the app's categories with this list, so ours
        // must live here (the Shortcut's native registration merges).
        // Titles are twins of QirshNotificationCategories in
        // BankMessageShortcuts.swift (pinned by a test).
        DarwinNotificationCategory(
          kUnrecognizedCaptureCategory,
          actions: [
            DarwinNotificationAction.plain(
              kActionEnableSmartAnalysis,
              'تفعيل التحليل الذكي',
              options: {DarwinNotificationActionOption.foreground},
            ),
            DarwinNotificationAction.plain(
              kActionAddManually,
              'إضافة يدويًا',
              options: {DarwinNotificationActionOption.foreground},
            ),
          ],
        ),
      ],
    );
    const windows = WindowsInitializationSettings(
      appName: 'قرش',
      appUserModelId: 'Qirsh.App',
      guid: '2a4f4ea2-1d7f-4c7d-9c6f-f0fdf6e44e34',
    );
    final settings = InitializationSettings(
      android: android,
      iOS: darwin,
      macOS: darwin,
      windows: windows,
    );

    await _plugin.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: (response) =>
          _handleNotificationPayload(response.payload,
              actionId: response.actionId),
      onDidReceiveBackgroundNotificationResponse: _backgroundTapHandler,
    );
    _initialized = true;

    final details = await _plugin.getNotificationAppLaunchDetails();
    final initialPayload = details?.notificationResponse?.payload;
    final initialRoute = _extractRoute(initialPayload);
    if (initialRoute != null) {
      CaptureRuntime.instance.seedInitialNavigation(initialRoute);
    }
    return _extractTransactionId(initialPayload);
  }

  /// Schedules must fire in the user's own timezone, not a fixed one. Resolve
  /// the device IANA zone and make it `tz.local`; fall back to Asia/Riyadh only
  /// if the platform can't report a zone (never leave scheduling broken).
  Future<void> _configureLocalTimezone() async {
    try {
      final name = await DeviceTimezone.getLocalTimezone();
      if (name != null) {
        tz.setLocalLocation(tz.getLocation(name));
        return;
      }
    } catch (_) {
      // An unreachable channel or an unknown zone name falls through to the
      // default below, exactly as before.
    }
    tz.setLocalLocation(tz.getLocation('Asia/Riyadh'));
  }

  Future<void> requestPermissionsIfNeeded() async {
    if (!_initialized) {
      await initialize();
    }

    if (Platform.isAndroid) {
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    } else if (Platform.isIOS) {
      await _plugin
          .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    }
  }

  Future<void> showReviewNotification({
    required String transactionId,
    String title = 'أكّد عملية',
    required String body,
    required NotificationPreferences preferences,
  }) async {
    debugPrint(
        '[Notif] showReviewNotification captureReview=${preferences.captureReview}');
    if (!preferences.captureReview) {
      return;
    }
    await _show(
      // MALI-061n §3 — stable logical identity from the transaction id (a
      // business key), not its unstable hashCode.
      id: notificationEventId('review', transactionId),
      title: title,
      body: body,
      notificationType: NotificationType.captureReview,
      preferences: preferences,
      details: NotificationDetails(
        android: AndroidNotificationDetails(
          _channel(_reviewChannelId),
          _channelCopy('تأكيد العمليات', 'تنبيهات العمليات التي تحتاج مراجعة',
                  'Confirm transactions', 'Transactions that need a review')
              .name,
          channelDescription: _channelCopy(
                  'تأكيد العمليات',
                  'تنبيهات العمليات التي تحتاج مراجعة',
                  'Confirm transactions',
                  'Transactions that need a review')
              .description,
          importance: Importance.max,
          priority: Priority.high,
          visibility: NotificationVisibility.private,
          // Action labels are per-notification, NOT per-channel: Android reads
          // them from each post. They were always free to follow the reader's
          // language and simply did not.
          actions: [
            AndroidNotificationAction(_actionConfirm,
                notificationLanguage == 'en' ? 'Confirm ✓' : 'تأكيد ✓'),
            AndroidNotificationAction(_actionDismiss,
                notificationLanguage == 'en' ? 'Dismiss' : 'تجاهل',
                cancelNotification: true),
          ],
        ),
        iOS: const DarwinNotificationDetails(
          presentBanner: true,
          presentList: true,
          presentBadge: false,
          presentSound: true,
          interruptionLevel: InterruptionLevel.active,
          categoryIdentifier: _reviewCategoryId,
        ),
      ),
      payload: CaptureNotificationPayload(
        kind: 'confirm',
        transactionId: transactionId,
      ).encode(),
    );
  }

  Future<void> showLightCaptureNotification({
    required String title,
    required String body,
    required NotificationPreferences preferences,
    required String stableId,
  }) async {
    debugPrint(
        '[Notif] showLightCapture captureLight=${preferences.captureLight}');
    if (!preferences.captureLight) {
      return;
    }
    await _show(
      // MALI-061n §3 — stable logical identity from the capture business key
      // (transaction id or immutable-content fingerprint), NEVER the display
      // text. The same capture notified twice replaces rather than duplicates.
      id: notificationEventId('captureLight', stableId),
      title: title,
      body: body,
      notificationType: NotificationType.captureLight,
      preferences: preferences,
      details: NotificationDetails(
        android: AndroidNotificationDetails(
          _channel(_lightChannelId),
          notificationLanguage == 'en'
              ? 'Captured transactions'
              : 'التقاط العمليات',
          channelDescription: notificationLanguage == 'en'
              ? 'Alerts the moment a transaction is captured from a bank message'
              : 'إشعارات فورية عند التقاط عملية من رسائل البنك',
          importance: Importance.high,
          priority: Priority.high,
          visibility: NotificationVisibility.private,
        ),
        iOS: const DarwinNotificationDetails(
          presentBanner: true,
          presentList: true,
          presentBadge: false,
          presentSound: true,
          interruptionLevel: InterruptionLevel.active,
        ),
      ),
    );
  }

  /// Returns whether the notification was actually handed to the OS —
  /// never throws (see docs/NOTIFICATION_PIPELINE_AUDIT.md), so the caller
  /// (settings_screen.dart's "send test notification" button) can show an
  /// accurate success/failure message instead of relying on an unhandled
  /// exception, which is exactly the failure mode this pipeline exists to
  /// remove.
  Future<bool> showTestNotification() async {
    final logId = await logService?.recordCreated(
        channel: _localChannel, notificationType: 'test');
    try {
      await requestPermissionsIfNeeded();
      await _plugin.show(
        id: 99001,
        title: 'إشعار تجريبي من قرش',
        body:
            'إذا ظهر هذا الإشعار فإن إذن إشعارات قِرش يعمل. لا يعني ذلك قراءة إشعارات المصرف.',
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _channel(_lightChannelId),
            notificationLanguage == 'en'
                ? 'Captured transactions'
                : 'التقاط العمليات',
            channelDescription: notificationLanguage == 'en'
                ? 'Light alerts when a confirmed transaction is captured'
                : 'إشعارات خفيفة عند التقاط عملية مؤكدة',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: const DarwinNotificationDetails(
            presentBanner: true,
            presentList: true,
            presentBadge: false,
            presentSound: true,
          ),
        ),
      );
      if (logId != null) {
        await logService?.recordSent(
            logId: logId, channel: _localChannel, notificationType: 'test');
      }
      return true;
    } catch (error, stackTrace) {
      if (logId != null) {
        await logService?.recordFailed(
          logId: logId,
          channel: _localChannel,
          notificationType: 'test',
          error: error,
          stackTrace: stackTrace,
        );
      }
      return false;
    }
  }

  Future<void> showMarketingNotification({
    required int id,
    required String title,
    required String body,
    required NotificationPreferences preferences,
    String route = '/dashboard',
  }) async {
    await _show(
      id: id,
      title: title,
      body: body,
      notificationType: NotificationType.marketing,
      preferences: preferences,
      details: NotificationDetails(
        android: AndroidNotificationDetails(
          _channel(_marketingChannelId),
          notificationLanguage == 'en' ? 'Qirsh tips' : 'رسائل ونصائح قرش',
          channelDescription: notificationLanguage == 'en'
              ? 'Messages from Qirsh that help you finish setup and find your summaries'
              : 'إشعارات من قرش تساعدك تكمل الإعداد وتكتشف ملخصاتك',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
        ),
        iOS: const DarwinNotificationDetails(
          presentBanner: true,
          presentList: true,
          presentBadge: false,
          presentSound: true,
        ),
      ),
      payload: CaptureNotificationPayload(
        kind: 'growth',
        route: route,
      ).encode(),
    );
  }

  Future<void> showBudgetAlert({
    required String title,
    required String body,
    required NotificationType type,
    required NotificationPreferences preferences,
    required int notifId,
  }) async {
    await _show(
      // MALI-061n §3 — the caller always supplies a stable
      // budgetAlertNotificationId(budgetId, periodStart, bucket); no display-text
      // fallback (which would change the id whenever the rendered text changed).
      id: notifId,
      title: title,
      body: body,
      notificationType: type,
      preferences: preferences,
      details: NotificationDetails(
        android: AndroidNotificationDetails(
          _channel(_budgetChannelId),
          notificationLanguage == 'en' ? 'Budget alerts' : 'تنبيهات الميزانيات',
          channelDescription: notificationLanguage == 'en'
              ? 'Alerts when a budget is nearly used up or gone over'
              : 'تنبيهات الاقتراب من الميزانية أو تجاوزها',
          importance: Importance.high,
          priority: Priority.high,
          visibility: NotificationVisibility.private,
        ),
        iOS: const DarwinNotificationDetails(
          presentBanner: true,
          presentList: true,
          presentBadge: false,
          presentSound: true,
        ),
      ),
    );
  }

  Future<void> showAchievementNotification({
    required String achievementKey,
    required String title,
    required String body,
    required NotificationPreferences preferences,
  }) async {
    await _show(
      // MALI-061n §3 — stable logical identity from the achievement KEY, never
      // the mutable/localizable title+body (which re-fired on any text change).
      id: achievementNotificationId(achievementKey),
      title: title,
      body: body,
      notificationType: NotificationType.achievements,
      preferences: preferences,
      details: NotificationDetails(
        android: AndroidNotificationDetails(
          _channel(_achievementChannelId),
          notificationLanguage == 'en' ? 'Achievements' : 'الإنجازات',
          channelDescription: notificationLanguage == 'en'
              ? 'Level and badge alerts'
              : 'تنبيهات المستوى والشارات',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
        ),
        iOS: const DarwinNotificationDetails(
          presentBanner: true,
          presentList: true,
          presentBadge: false,
          presentSound: true,
        ),
      ),
    );
  }

  Future<void> schedulePlannedNotifications(
    List<PlannedLocalNotification> notifications,
  ) async {
    // MALI-025 — schedule within the pending-capacity budget (iOS silently
    // drops requests past ~64 pending). Reserve headroom for immediate alerts,
    // prefer importance then nearest-due, and roll the window forward instead of
    // burning the budget on far-future recurrences.
    final Set<int> managedPending;
    try {
      if (!_initialized) {
        await initialize();
      }
      final pending = await _plugin.pendingNotificationRequests();
      managedPending = {
        for (final request in pending)
          if (_isManagedScheduledId(request.id)) request.id,
      };
    } catch (error) {
      // Setup (init/read-pending) failed — nothing durable was scheduled yet.
      // Stop rather than schedule on top of an uncertain plugin state.
      debugPrint('[Notif] schedulePlannedNotifications setup failed: $error');
      return;
    }

    final byId = {for (final n in notifications) n.id: n};
    final plan = _capacityPlanner.plan(
      currentManagedPending: managedPending,
      desired: [
        for (final n in notifications)
          ScheduleCandidate(
            id: n.id,
            due: n.scheduledAtRiyadh,
            priority: _plannedPriority(n.kind),
          ),
      ],
      now: DateTime.now(),
    );

    // Cancel stale/dropped managed pending before adding replacements.
    for (final staleId in plan.toCancel) {
      try {
        await _plugin.cancel(id: staleId);
      } catch (_) {}
    }

    for (final candidate in plan.toSchedule) {
      final notification = byId[candidate.id];
      if (notification == null) continue;
      final notificationType = notification.kind.name;
      final logId = await logService?.recordCreated(
        channel: _localChannel,
        notificationType: notificationType,
      );
      try {
        await _plugin.zonedSchedule(
          id: notification.id,
          title: notification.title,
          body: notification.body,
          scheduledDate: _riyadhDate(notification.scheduledAtRiyadh),
          notificationDetails: _detailsFor(notification.kind),
          payload: CaptureNotificationPayload(
            kind: notification.payload ?? notification.kind.name,
            route: _routeFor(notification.payload),
            notificationLogId: logId,
            notificationType: notificationType,
          ).encode(),
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        );
        if (logId != null) {
          await logService?.recordSent(
            logId: logId,
            channel: _localChannel,
            notificationType: notificationType,
          );
        }
      } catch (error, stackTrace) {
        if (logId != null) {
          await logService?.recordFailed(
            logId: logId,
            channel: _localChannel,
            notificationType: notificationType,
            error: error,
            stackTrace: stackTrace,
          );
        }
      }
    }

    // MALI-025 — verify the actual pending set instead of assuming every
    // schedule was accepted. Safe count only, no financial content.
    try {
      final after = await _plugin.pendingNotificationRequests();
      final managed = after.where((r) => _isManagedScheduledId(r.id)).length;
      debugPrint('[Notif] window: planned=${plan.toSchedule.length} '
          'managedPending=$managed cap=${_capacityPlanner.capacity}');
    } catch (_) {
      // Verification is best-effort diagnostics.
    }
  }

  /// Ids the CAPACITY planner owns: bill/subscription reminders and the weekly
  /// report. Never touches immediate/foreign notifications.
  static bool _isManagedScheduledId(int id) =>
      id == _weeklyReportId ||
      id == dailyReminderNotificationId ||
      (id >= 92000 && id < 992000);

  /// Every app-managed SCHEDULED reminder id (bill/subscription, weekly report,
  /// and the RETIRED streak reminder). Public so the sign-out cancellation set
  /// is directly testable. Excludes immediate/foreign ids so we never cancel
  /// someone else's request. The retired streak id stays in this set on purpose:
  /// an install that scheduled one before V1 removed the feature must still have
  /// it cancelled rather than left firing forever.
  static bool isManagedReminderId(int id) =>
      _isManagedScheduledId(id) || id == retiredStreakReminderId;

  /// V1 retirement — cancel any streak reminder a previous version scheduled.
  /// Removing the feature from the code does NOT unschedule what the OS is
  /// already holding: without this, every device that had one keeps receiving
  /// it indefinitely, from a feature that no longer exists.
  Future<void> cancelRetiredStreakReminder() async {
    try {
      if (!_initialized) await initialize();
      await _plugin.cancel(id: retiredStreakReminderId);
    } catch (_) {
      // Best effort: the next sign-out or planning cycle also clears it.
    }
  }

  /// MALI-019 §10 — cancel every app-managed scheduled reminder so a sign-out /
  /// ownership change never leaves the previous user's bill/weekly/streak
  /// reminders pending. Best-effort; the next planning cycle reconciles anyway.
  Future<void> cancelScheduledReminders() async {
    try {
      if (!_initialized) await initialize();
      final pending = await _plugin.pendingNotificationRequests();
      for (final request in pending) {
        if (isManagedReminderId(request.id)) {
          await _plugin.cancel(id: request.id);
        }
      }
    } catch (_) {
      // Best-effort — a failure here must never block the sign-out wipe.
    }
  }

  static int _plannedPriority(PlannedNotificationKind kind) {
    switch (kind) {
      case PlannedNotificationKind.subscriptionReminder:
        return 3; // time-sensitive bill/subscription due dates
      case PlannedNotificationKind.weeklyReport:
        return 1; // low priority — dropped first under pressure
      case PlannedNotificationKind.dailyReminder:
        return 2; // above the weekly digest, below a dated bill
    }
  }

  Future<void> showGoalMilestoneNotification({
    required GoalMilestoneNotification notification,
    required NotificationPreferences preferences,
  }) async {
    await _show(
      id: goalMilestoneNotificationId(notification.goalId),
      title: notification.title,
      body: notification.body,
      notificationType: NotificationType.goalMilestone,
      preferences: preferences,
      details: NotificationDetails(
        android: AndroidNotificationDetails(
          _channel(_goalMilestoneChannelId),
          notificationLanguage == 'en'
              ? 'Goal milestones'
              : 'احتفالات الأهداف',
          channelDescription: notificationLanguage == 'en'
              ? 'Gentle alerts when a goal reaches a milestone'
              : 'تنبيهات لطيفة عند الوصول لمراحل الأهداف',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
        ),
        iOS: const DarwinNotificationDetails(
          presentBanner: true,
          presentList: true,
          presentBadge: false,
          presentSound: true,
        ),
      ),
      payload: const CaptureNotificationPayload(
        kind: 'goals',
        route: '/budgets',
      ).encode(),
    );
  }

  Future<void> _show({
    required int id,
    required String title,
    required String body,
    required NotificationType notificationType,
    required NotificationPreferences preferences,
    required NotificationDetails details,
    String? payload,
  }) async {
    debugPrint(
        '[Notif] _show type=$notificationType enabled=${preferences.isEnabled(notificationType)}');
    if (!preferences.isEnabled(notificationType)) {
      return;
    }

    // MALI-019 §6 — lock-screen privacy. The OS-displayed content is generic
    // when redaction is on (no amount/merchant/account/sender/balance/name/raw
    // SMS); the in-app inbox history below keeps the real content, shown only
    // inside the app behind its lock. The tap payload is unchanged (opaque id).
    final bool redact = preferences.hideLockScreenContent;
    final (String shownTitle, String shownBody) =
        redact
            ? redactedContentFor(notificationType,
                languageCode: notificationLanguage)
            : (title, body);

    final decodedPayload = CaptureNotificationPayload.tryDecode(payload);
    final logId = await _createLog(
      notificationType: notificationType,
      relatedEntityId: decodedPayload?.transactionId,
    );
    final effectivePayload =
        _attachTracking(decodedPayload, payload, logId, notificationType);

    // Capture notifications (bank SMS results) are time-sensitive — show immediately.
    final isCaptureNotification =
        notificationType == NotificationType.captureReview ||
            notificationType == NotificationType.captureLight;
    // Everything from here down — including initialize() and the
    // permissions prompt, not just the plugin call itself — must never
    // throw into the caller; several call sites are unawaited
    // fire-and-forget. See docs/NOTIFICATION_PIPELINE_AUDIT.md.
    try {
      if (!_initialized) {
        await initialize();
      }
      if (isCaptureNotification) {
        await _requestCaptureNotificationPermissionsIfPossible();
      }
      final now = tz.TZDateTime.now(tz.local);
      if (!isCaptureNotification && _isQuietHour(now, preferences)) {
        await _plugin.zonedSchedule(
          id: id,
          title: shownTitle,
          body: shownBody,
          scheduledDate: _nextAllowedDate(now, preferences),
          notificationDetails: details,
          payload: effectivePayload,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        );
        await _recordSent(logId, notificationType);
        await _recordHistory(
            id, title, body, notificationType, effectivePayload);
        return;
      }

      // MALI-019 §9 — never log the rendered title/body (may hold merchant/
      // amount); the id + type are enough to trace.
      debugPrint('[Notif] plugin.show id=$id');
      await _plugin.show(
        id: id,
        title: shownTitle,
        body: shownBody,
        notificationDetails: details,
        payload: effectivePayload,
      );
      debugPrint('[Notif] plugin.show done');
      await _recordSent(logId, notificationType);
      await _recordHistory(id, title, body, notificationType, effectivePayload);
    } catch (error, stackTrace) {
      // A show/schedule failure must never crash the caller (many call sites
      // are unawaited fire-and-forget) — record it and stop here instead of
      // rethrowing. See docs/NOTIFICATION_PIPELINE_AUDIT.md.
      debugPrint('[Notif] show/schedule failed: $error');
      await _recordFailed(logId, notificationType, error, stackTrace);
    }
  }

  /// Starts a new logged attempt, best-effort. Returns null when
  /// [logService] isn't wired (e.g. a test that never set it) — every other
  /// tracking call below is a no-op when [logId] is null.
  Future<String?> _createLog({
    required NotificationType notificationType,
    String? relatedEntityId,
  }) {
    final service = logService;
    if (service == null) return Future.value(null);
    return service.recordCreated(
      channel: _localChannel,
      notificationType: notificationType.name,
      relatedEntityType: relatedEntityId != null ? 'transaction' : null,
      relatedEntityId: relatedEntityId,
    );
  }

  Future<void> _recordSent(String? logId, NotificationType notificationType) {
    if (logId == null) return Future.value();
    return logService?.recordSent(
          logId: logId,
          channel: _localChannel,
          notificationType: notificationType.name,
        ) ??
        Future.value();
  }

  Future<void> _recordFailed(
    String? logId,
    NotificationType notificationType,
    Object error,
    StackTrace stackTrace,
  ) {
    if (logId == null) return Future.value();
    return logService?.recordFailed(
          logId: logId,
          channel: _localChannel,
          notificationType: notificationType.name,
          error: error,
          stackTrace: stackTrace,
        ) ??
        Future.value();
  }

  /// Merges [logId] and the [notificationType] name into the notification's
  /// own payload so a later tap can be correlated back to this exact attempt
  /// — see [_handleNotificationPayload]. Existing kind/transactionId/route
  /// routing fields are preserved unchanged.
  String? _attachTracking(
    CaptureNotificationPayload? decoded,
    String? originalPayload,
    String? logId,
    NotificationType notificationType,
  ) {
    if (logId == null) return originalPayload;
    final base = decoded ?? const CaptureNotificationPayload(kind: '');
    return CaptureNotificationPayload(
      kind: base.kind,
      transactionId: base.transactionId,
      route: base.route,
      notificationLogId: logId,
      notificationType: notificationType.name,
    ).encode();
  }

  Future<void> _requestCaptureNotificationPermissionsIfPossible() async {
    try {
      if (Platform.isAndroid) {
        await _plugin
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission();
        return;
      }
      if (Platform.isIOS) {
        final ios = _plugin.resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>();
        final permissions = await ios?.checkPermissions();
        if (permissions?.isAlertEnabled == true &&
            permissions?.isSoundEnabled == true) {
          return;
        }
        await ios?.requestPermissions(alert: true, badge: true, sound: true);
      }
    } catch (_) {
      // If iOS/Android refuses to prompt from the current execution context,
      // still attempt plugin.show below; denied users also keep the in-app
      // notification history entry.
    }
  }

  /// يسجّل الإشعار في سجل الرسائل داخل التطبيق. إشعارات الـ marketing
  /// تُسجَّل بالفعل من NotificationJourneyService/GrowthCampaignService
  /// بمعرّفات أدق فلا تُكرَّر هنا.
  Future<void> _recordHistory(
    int id,
    String title,
    String body,
    NotificationType type,
    String? payload,
  ) async {
    final store = historyStore;
    if (store == null || type == NotificationType.marketing) {
      return;
    }
    final decoded = CaptureNotificationPayload.tryDecode(payload);
    try {
      await store(
        NotificationHistoryEntry(
          id: decoded?.transactionId ?? 'notif_$id',
          kind: type.name,
          title: title,
          body: body,
          route: decoded?.route ??
              (decoded?.transactionId != null ? '/transactions' : null),
          sentAt: DateTime.now().toUtc(),
        ),
      );
    } catch (_) {
      // السجل ثانوي — لا يؤثر على عرض الإشعار نفسه.
    }
  }

  bool _isQuietHour(
    tz.TZDateTime dateTime,
    NotificationPreferences preferences,
  ) {
    if (!preferences.quietHoursEnabled) return false;
    final hour = dateTime.hour;
    if (preferences.quietHoursStartHour > preferences.quietHoursEndHour) {
      return hour >= preferences.quietHoursStartHour ||
          hour < preferences.quietHoursEndHour;
    }
    return hour >= preferences.quietHoursStartHour &&
        hour < preferences.quietHoursEndHour;
  }

  tz.TZDateTime _nextAllowedDate(
    tz.TZDateTime dateTime,
    NotificationPreferences preferences,
  ) {
    if (!_isQuietHour(dateTime, preferences)) {
      return dateTime;
    }
    final sameDay = tz.TZDateTime(
      tz.local,
      dateTime.year,
      dateTime.month,
      dateTime.day,
      preferences.quietHoursEndHour,
    );
    if (dateTime.hour < preferences.quietHoursEndHour) {
      return sameDay;
    }
    return sameDay.add(const Duration(days: 1));
  }

  String? _extractTransactionId(String? payload) =>
      CaptureNotificationPayload.tryDecode(payload)?.transactionId;

  String? _extractRoute(String? payload) =>
      CaptureNotificationPayload.tryDecode(payload)?.route;

  /// Records the 'opened' lifecycle event for a foreground tap or
  /// Confirm/Dismiss quick action — both are `didReceive response:` on iOS,
  /// i.e. the user interacted with the notification. Idempotent
  /// ([NotificationLogService.recordOpened] dedupes repeated taps).
  Future<void> _recordOpenedFromPayload(String? payload) {
    final decoded = CaptureNotificationPayload.tryDecode(payload);
    final logId = decoded?.notificationLogId;
    if (logId == null) return Future.value();
    return logService?.recordOpened(
          logId: logId,
          channel: _localChannel,
          notificationType: decoded?.notificationType ?? 'unknown',
          relatedEntityType:
              decoded?.transactionId != null ? 'transaction' : null,
          relatedEntityId: decoded?.transactionId,
        ) ??
        Future.value();
  }

  /// Test seam for the foreground tap/quick-action path — the real entry
  /// point is [onDidReceiveNotificationResponse] registered in [initialize].
  /// Unlike production call sites, this awaits the opened-event write so
  /// tests can assert on it deterministically.
  @visibleForTesting
  Future<void> debugHandleNotificationTap(
    String? payload, {
    String? actionId,
  }) {
    return _handleNotificationPayload(payload, actionId: actionId);
  }

  Future<void> _handleNotificationPayload(
    String? payload, {
    String? actionId,
  }) async {
    await _recordOpenedFromPayload(payload);
    final transactionId = _extractTransactionId(payload);
    if (transactionId != null) {
      if (actionId == _actionConfirm) {
        // التطبيق شغال — تأكيد مباشر عبر الـ usecase (يسجّل الـ engagement
        // ويحدّث الواجهة) بدلاً من فتح شاشة التأكيد.
        CaptureRuntime.instance
            .requestQuickAction(transactionId, confirm: true);
      } else if (actionId == _actionDismiss) {
        // تجاهل — حذف عبر الـ repository المفتوح بدلاً من فتح اتصال DB ثانٍ.
        CaptureRuntime.instance
            .requestQuickAction(transactionId, confirm: false);
      } else {
        // ضغطة عادية على الـ notification → افتح الـ confirm sheet.
        CaptureRuntime.instance.requestConfirmation(transactionId);
      }
      return;
    }
    final route = _extractRoute(payload);
    if (route != null) {
      CaptureRuntime.instance.requestNavigation(route);
    }
  }

  NotificationDetails _detailsFor(PlannedNotificationKind kind) {
    switch (kind) {
      case PlannedNotificationKind.dailyReminder:
        return NotificationDetails(
          android: AndroidNotificationDetails(
            _channel(_dailyReminderChannelId),
            notificationLanguage == 'en'
                ? 'Daily reminder'
                : 'التذكير اليومي',
            channelDescription: notificationLanguage == 'en'
                ? 'A daily nudge to log your spending'
                : 'تذكير يومي بتسجيل المصروفات',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
          ),
          iOS: const DarwinNotificationDetails(
            presentBanner: true,
            presentList: true,
            presentBadge: false,
            presentSound: false,
          ),
        );
      case PlannedNotificationKind.weeklyReport:
        return NotificationDetails(
          android: AndroidNotificationDetails(
            _channel(_weeklyReportChannelId),
            notificationLanguage == 'en'
                ? 'Weekly reports'
                : 'التقارير الأسبوعية',
            channelDescription: notificationLanguage == 'en'
                ? 'A gentle weekly nudge to read your report'
                : 'تذكير أسبوعي لطيف لقراءة التقرير',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
          ),
          iOS: const DarwinNotificationDetails(
            presentBanner: true,
            presentList: true,
            presentBadge: false,
            presentSound: false,
          ),
        );
      case PlannedNotificationKind.subscriptionReminder:
        return NotificationDetails(
          android: AndroidNotificationDetails(
            _channel(_billReminderChannelId),
            notificationLanguage == 'en'
                ? 'Bill reminders'
                : 'تذكير الفواتير',
            channelDescription: notificationLanguage == 'en'
                ? 'A local reminder of subscription and instalment dates'
                : 'تذكير محلي بمواعيد الاشتراكات والأقساط',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
          ),
          iOS: const DarwinNotificationDetails(
            presentBanner: true,
            presentList: true,
            presentBadge: false,
            presentSound: false,
          ),
        );
    }
  }

  tz.TZDateTime _riyadhDate(DateTime dateTime) {
    return tz.TZDateTime(
      tz.local,
      dateTime.year,
      dateTime.month,
      dateTime.day,
      dateTime.hour,
      dateTime.minute,
      dateTime.second,
    );
  }

  String? _routeFor(String? payload) {
    return switch (payload) {
      'reports' => '/reports',
      'bills' => '/',
      _ => null,
    };
  }

  /// Test seam for the background confirm/dismiss path — the real entry point
  /// is the notification plugin's background isolate callback below.
  @visibleForTesting
  static Future<void> debugRunBackgroundAction(
    String transactionId, {
    required bool confirm,
  }) =>
      _runBackgroundAction(transactionId, confirm: confirm);

  @pragma('vm:entry-point')
  static void _backgroundTapHandler(NotificationResponse response) {
    final actionId = response.actionId;
    if (actionId != _actionConfirm && actionId != _actionDismiss) return;
    final transactionId =
        CaptureNotificationPayload.tryDecode(response.payload)?.transactionId;
    if (transactionId == null) return;
    _runBackgroundAction(transactionId, confirm: actionId == _actionConfirm);
  }

  /// G6: applies a background confirm/dismiss through the SAME repository calls
  /// the foreground replay uses, so the outbox state is identical (confirm →
  /// update; dismiss → soft-delete + `delete`, which coalesces a never-sent
  /// create away and turns an in-flight create into a delete — it never drops
  /// an in-flight create or invents a base token). Only a still-`pending` row
  /// is touched, as before; replay of the recorded action stays idempotent.
  @visibleForTesting
  static Future<void> applyBackgroundActionToDb(
    AppDatabase db,
    String transactionId, {
    required bool confirm,
    PlanningCutoverCoordinator? coordinator,
    LedgerOutboxQueue? queue,
  }) async {
    final repo = DriftTransactionRepository(
      db,
      outboxQueue:
          queue ?? buildLedgerOutboxQueue(db, coordinator: coordinator),
    );
    await db.transaction(() async {
      final tx = await repo.getById(transactionId);
      if (tx == null || tx.status != TransactionStatus.pending) return;
      if (confirm) {
        await repo.confirm(transactionId);
      } else {
        await repo.deleteTransaction(transactionId);
      }
    });
  }

  static Future<void> _runBackgroundAction(String transactionId,
      {required bool confirm}) async {
    WidgetsFlutterBinding.ensureInitialized();
    // يُسجَّل الإجراء دائمًا ليُعاد تطبيقه عند أول فتح للتطبيق: هذا الـ isolate
    // الخلفي لا يملك حالة التطبيق الأمامي كاملة (الـ overrides الشخصية والملكية
    // تعيش في ذاكرة الواجهة فقط)، فنُسجّل النية بدل تعديل Drift مباشرةً هنا.
    // إعادة التطبيق آمنة التكرار (تأكيد مؤكَّد/حذف محذوف) والمزامنة تتم خلفيًا
    // عبر outbox/push عند الفتح.
    await PendingNotificationActions.record(transactionId, confirm: confirm);
    // MALI-069n §Blocker-1 — bind this background isolate to the current admission
    // generation and re-validate at every boundary. A confirm/dismiss for a
    // previous session's transaction must never be applied to a new owner's DB.
    final ownershipGuard = OwnershipGuard();
    final AppDatabase db;
    final AdmissionToken admissionToken;
    try {
      // Capturing the admission token and opening the SECONDARY connection are in
      // the same guarded block: a locked-device Keychain read (or the admission
      // check / lease refusal inside openSecondary) simply defers — the action is
      // already recorded above and replays under its owning session at next open.
      admissionToken = await ownershipGuard.capture();
      // MALI-069n §6/§Blocker-1 — a bounded SECONDARY connection in the
      // notification background isolate: same key + PRAGMA contract, no
      // concurrent migrations, and a CROSS-ISOLATE shared lease (refused while
      // file-exclusive maintenance is in progress). Points 1/2 admission checks
      // run inside openSecondary. Closed in the finally below (releases the lease).
      db = await AppDatabase.openSecondary(
        leaseManager: await AppDatabase.appSupportLeaseManager(),
        ownershipGuard: ownershipGuard,
        admissionToken: admissionToken,
      );
    } catch (_) {
      // الجهاز غالباً مقفول ومفتاح التشفير غير متاح من الـ Keychain — أو تغيّرت
      // الملكية (StaleOwnershipException). الإجراء مسجَّل أعلاه ويُطبَّق (مع فحص
      // ملكية) عند أول فتح للتطبيق بدلاً من فقدانه.
      return;
    }
    try {
      // Point 3/4 — re-validate immediately before the Drift commit (which is
      // also the native acknowledgement of the action). If ownership changed,
      // skip the write entirely; the recorded action replays under its owning
      // session, never here.
      if (!await ownershipGuard.isCurrent(admissionToken)) {
        return;
      }
      // تحديث محلي فوري عبر نفس المستودع/الـ outbox المستخدم في الواجهة
      // (G6): التأكيد/الحذف يسجّلان نية المزامنة في نفس المعاملة المحلية.
      await applyBackgroundActionToDb(
        db,
        transactionId,
        confirm: confirm,
        coordinator: await resolveCutoverCoordinator(db),
      );
    } catch (_) {
      // الإجراء مسجَّل بالفعل لإعادة التطبيق — لا شيء يُفقد هنا.
    } finally {
      await db.close();
    }
  }
}
