import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

import '../../../data/db/app_database.dart';
import '../../../domain/entities/engagement_entities.dart';
import '../../../domain/services/notification_capacity_planner.dart';
import '../../../domain/services/notification_planner.dart';
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

  /// Clamp any id to a non-negative 31-bit int. The Android plugin reads the id
  /// as a Java `Integer`; a Dart hashCode > 2^31 throws (Long→Integer) and the
  /// notification is silently dropped. Every id goes through here.
  static int _safeId(int raw) => raw & 0x7FFFFFFF;

  /// MALI-019 §6 — the redaction contract: generic, financial-data-free
  /// lock-screen content per type. Used by the local path; the APNs path honors
  /// the synced preference server-side (C6 coordination + edge policy). Public
  /// so the privacy guarantee is directly testable.
  static (String, String) redactedContentFor(NotificationType type) {
    switch (type) {
      case NotificationType.captureReview:
      case NotificationType.captureLight:
        return ('قرش', 'عملية بحاجة إلى مراجعة — افتح التطبيق لعرض التفاصيل');
      case NotificationType.budgetWarning:
      case NotificationType.budgetOver:
        return ('قرش', 'لديك تنبيه ميزانية — افتح التطبيق');
      case NotificationType.subscriptionReminder:
        return ('قرش', 'لديك تذكير مالي — افتح التطبيق');
      case NotificationType.goalMilestone:
        return ('قرش', 'لديك تحديث هدف — افتح التطبيق');
      case NotificationType.weeklyReport:
        return ('قرش', 'تقريرك الأسبوعي جاهز — افتح التطبيق');
      case NotificationType.achievements:
        return ('قرش', 'لديك إنجاز جديد — افتح التطبيق');
      case NotificationType.streakReminder:
        return ('قرش', 'لديك تذكير — افتح التطبيق');
      case NotificationType.marketing:
        return ('قرش', 'لديك رسالة — افتح التطبيق');
    }
  }

  static const String _reviewChannelId = 'capture_review';
  // v2 because Android keeps the original channel importance forever after it
  // is created. The old capture_light channel was low importance, so confirmed
  // captures could be saved without a visible banner.
  static const String _lightChannelId = 'capture_light_v2';
  static const String _marketingChannelId = 'qirsh_growth';
  static const String _budgetChannelId = 'budget_alerts';
  static const String _achievementChannelId = 'achievement_alerts';
  static const String _streakChannelId = 'streak_reminders';
  static const String _weeklyReportChannelId = 'weekly_reports';
  static const String _billReminderChannelId = 'bill_reminders';
  static const String _goalMilestoneChannelId = 'goal_milestones';
  static const int _streakReminderId = 88008;
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
      final name = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(name));
    } catch (_) {
      tz.setLocalLocation(tz.getLocation('Asia/Riyadh'));
    }
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
      details: const NotificationDetails(
        android: AndroidNotificationDetails(
          _reviewChannelId,
          'تأكيد العمليات',
          channelDescription: 'تنبيهات العمليات التي تحتاج مراجعة',
          importance: Importance.max,
          priority: Priority.high,
          visibility: NotificationVisibility.private,
          actions: [
            AndroidNotificationAction(_actionConfirm, 'تأكيد ✓'),
            AndroidNotificationAction(_actionDismiss, 'تجاهل',
                cancelNotification: true),
          ],
        ),
        iOS: DarwinNotificationDetails(
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
    String? stableId,
  }) async {
    debugPrint(
        '[Notif] showLightCapture captureLight=${preferences.captureLight}');
    if (!preferences.captureLight) {
      return;
    }
    await _show(
      // Idempotent per transaction (or per content when no id is available):
      // the same capture notified twice replaces rather than duplicates.
      id: _safeId((stableId ?? '$title|$body').hashCode),
      title: title,
      body: body,
      notificationType: NotificationType.captureLight,
      preferences: preferences,
      details: const NotificationDetails(
        android: AndroidNotificationDetails(
          _lightChannelId,
          'التقاط العمليات',
          channelDescription: 'إشعارات فورية عند التقاط عملية من رسائل البنك',
          importance: Importance.high,
          priority: Priority.high,
          visibility: NotificationVisibility.private,
        ),
        iOS: DarwinNotificationDetails(
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
            'لو ظهر الإشعار ده، إذن إشعارات قرش شغال. ده لا يعني قراءة إشعارات البنك.',
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            _lightChannelId,
            'التقاط العمليات',
            channelDescription: 'إشعارات خفيفة عند التقاط عملية مؤكدة',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(
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
      details: const NotificationDetails(
        android: AndroidNotificationDetails(
          _marketingChannelId,
          'رسائل ونصائح قرش',
          channelDescription:
              'إشعارات من قرش تساعدك تكمل الإعداد وتكتشف ملخصاتك',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
        ),
        iOS: DarwinNotificationDetails(
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
    int? notifId,
  }) async {
    await _show(
      id: notifId ?? _safeId(title.hashCode ^ body.hashCode),
      title: title,
      body: body,
      notificationType: type,
      preferences: preferences,
      details: const NotificationDetails(
        android: AndroidNotificationDetails(
          _budgetChannelId,
          'تنبيهات الميزانيات',
          channelDescription: 'تنبيهات الاقتراب من الميزانية أو تجاوزها',
          importance: Importance.high,
          priority: Priority.high,
          visibility: NotificationVisibility.private,
        ),
        iOS: DarwinNotificationDetails(
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
      details: const NotificationDetails(
        android: AndroidNotificationDetails(
          _achievementChannelId,
          'الإنجازات',
          channelDescription: 'تنبيهات المستوى والشارات',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
        ),
        iOS: DarwinNotificationDetails(
          presentBanner: true,
          presentList: true,
          presentBadge: false,
          presentSound: true,
        ),
      ),
    );
  }

  Future<void> scheduleStreakReminder({
    required bool hasActivityToday,
    required NotificationPreferences preferences,
  }) async {
    if (!preferences.streakReminder || hasActivityToday) {
      await _plugin.cancel(id: _streakReminderId);
      return;
    }

    final now = tz.TZDateTime.now(tz.local);
    var scheduled = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      20,
    );
    if (!scheduled.isAfter(now)) {
      scheduled = scheduled.add(const Duration(days: 1));
    }
    scheduled = _nextAllowedDate(scheduled, preferences);

    final logId = await logService?.recordCreated(
        channel: _localChannel, notificationType: 'streak_reminder');
    try {
      if (!_initialized) {
        await initialize();
      }
      await _plugin.zonedSchedule(
        id: _streakReminderId,
        title: 'ذكّر نفسك بلحظة سريعة',
        body: 'عملية واحدة اليوم تكفي للمحافظة على السلسلة.',
        scheduledDate: scheduled,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            _streakChannelId,
            'تذكير السلسلة',
            channelDescription: 'تذكير مسائي لطيف عند غياب النشاط اليومي',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
          ),
          iOS: DarwinNotificationDetails(
            presentBanner: true,
            presentList: true,
            presentBadge: false,
            presentSound: false,
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      );
      if (logId != null) {
        await logService?.recordSent(
          logId: logId,
          channel: _localChannel,
          notificationType: 'streak_reminder',
        );
      }
    } catch (error, stackTrace) {
      if (logId != null) {
        await logService?.recordFailed(
          logId: logId,
          channel: _localChannel,
          notificationType: 'streak_reminder',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
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
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
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
      final managed =
          after.where((r) => _isManagedScheduledId(r.id)).length;
      debugPrint('[Notif] window: planned=${plan.toSchedule.length} '
          'managedPending=$managed cap=${_capacityPlanner.capacity}');
    } catch (_) {
      // Verification is best-effort diagnostics.
    }
  }

  /// Ids this planner owns: bill/subscription reminders and the weekly report.
  /// Never touches immediate/foreign notifications.
  static bool _isManagedScheduledId(int id) =>
      id == _weeklyReportId || (id >= 92000 && id < 992000);

  static int _plannedPriority(PlannedNotificationKind kind) {
    switch (kind) {
      case PlannedNotificationKind.subscriptionReminder:
        return 3; // time-sensitive bill/subscription due dates
      case PlannedNotificationKind.weeklyReport:
        return 1; // low priority — dropped first under pressure
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
      details: const NotificationDetails(
        android: AndroidNotificationDetails(
          _goalMilestoneChannelId,
          'احتفالات الأهداف',
          channelDescription: 'تنبيهات لطيفة عند الوصول لمراحل الأهداف',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
        ),
        iOS: DarwinNotificationDetails(
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
        redact ? redactedContentFor(notificationType) : (title, body);

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
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
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
      case PlannedNotificationKind.weeklyReport:
        return const NotificationDetails(
          android: AndroidNotificationDetails(
            _weeklyReportChannelId,
            'التقارير الأسبوعية',
            channelDescription: 'تذكير أسبوعي لطيف لقراءة التقرير',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
          ),
          iOS: DarwinNotificationDetails(
            presentBanner: true,
            presentList: true,
            presentBadge: false,
            presentSound: false,
          ),
        );
      case PlannedNotificationKind.subscriptionReminder:
        return const NotificationDetails(
          android: AndroidNotificationDetails(
            _billReminderChannelId,
            'تذكير الفواتير',
            channelDescription: 'تذكير محلي بمواعيد الاشتراكات والأقساط',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
          ),
          iOS: DarwinNotificationDetails(
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

  static Future<void> _runBackgroundAction(String transactionId,
      {required bool confirm}) async {
    WidgetsFlutterBinding.ensureInitialized();
    // يُسجَّل الإجراء دائمًا لإعادة تطبيقه عبر الـ routed repository عند أول
    // فتح: في هذا الـ isolate لا نعرف قيمة transactions_supabase_primary
    // الفعلية (الـ overrides الشخصية تعيش في ذاكرة التطبيق الأمامي فقط)،
    // وتعديل Drift وحده يعني ضياع التأكيد/الحذف على الخادم عندما يكون
    // Supabase هو المرجع — أول قراءة من الخادم كانت تعيد الحالة القديمة.
    // إعادة التطبيق آمنة التكرار في وضع Drift (تأكيد مؤكَّد/حذف محذوف).
    await PendingNotificationActions.record(transactionId, confirm: confirm);
    final AppDatabase db;
    try {
      db = await AppDatabase.open();
    } catch (_) {
      // الجهاز غالباً مقفول ومفتاح التشفير غير متاح من الـ Keychain —
      // الإجراء مسجَّل أعلاه ويُطبَّق عند أول فتح للتطبيق بدلاً من فقدانه.
      return;
    }
    try {
      // تحديث محلي فوري: هو المرجع في وضع Drift، ومجرد تحديث تجميلي للمرآة
      // في وضع Supabase حتى لا يظهر التناقض قبل إعادة التطبيق أعلاه.
      if (confirm) {
        await db.customUpdate(
          "UPDATE transactions SET status = 'confirmed', updated_at = ? "
          "WHERE id = ? AND status = 'pending';",
          variables: [
            Variable.withString(DateTime.now().toUtc().toIso8601String()),
            Variable.withString(transactionId),
          ],
        );
      } else {
        // Atomic: the local delete, the outbox-create removal, and the
        // tombstone must all commit together, or none — otherwise an
        // interruption between them could leave the `create` behind and
        // resurrect the dismissed capture (docs/NOTIFICATION_FORENSIC_AUDIT.md
        // C1). One Drift transaction = one SQLite write lock, so it is also
        // serialized against any concurrent connection.
        await db.transaction(() async {
          // Read server state BEFORE deleting so we can tombstone if it already
          // reached Supabase.
          final existing = await db.customSelect(
            "SELECT server_id FROM transactions "
            "WHERE id = ? AND status = 'pending';",
            variables: [Variable.withString(transactionId)],
          ).getSingleOrNull();
          final serverId = existing?.readNullable<String>('server_id');

          await db.customUpdate(
            "DELETE FROM transactions WHERE id = ? AND status = 'pending';",
            variables: [Variable.withString(transactionId)],
          );

          // A captured pending row already enqueued an outbox `create`. Drop it
          // so a dismissed capture is never pushed to the server...
          await db.customUpdate(
            "DELETE FROM ledger_sync_outbox "
            "WHERE transaction_id = ? AND operation = 'create';",
            variables: [Variable.withString(transactionId)],
          );
          // ...and if it already reached the server, enqueue a tombstone delete
          // so the next push removes it there too (else the pull re-imports it).
          if (serverId != null) {
            final now = DateTime.now().toUtc().toIso8601String();
            await db.customInsert(
              "INSERT INTO ledger_sync_outbox(id, transaction_id, operation, "
              "payload_json, attempt_count, created_at, updated_at) "
              "VALUES (?, ?, 'delete', ?, 0, ?, ?);",
              variables: [
                Variable.withString(
                    'bgdel_${transactionId}_${DateTime.now().microsecondsSinceEpoch}'),
                Variable.withString(transactionId),
                Variable.withString(jsonEncode(
                    {'local_id': transactionId, 'server_id': serverId})),
                Variable.withString(now),
                Variable.withString(now),
              ],
            );
          }
        });
      }
    } catch (_) {
      // الإجراء مسجَّل بالفعل لإعادة التطبيق — لا شيء يُفقد هنا.
    } finally {
      await db.close();
    }
  }
}
