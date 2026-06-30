import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

import '../../../data/db/app_database.dart';
import '../../../domain/entities/engagement_entities.dart';
import '../../../domain/services/notification_planner.dart';
import '../capture_runtime.dart';

class CaptureNotificationPayload {
  const CaptureNotificationPayload({
    required this.kind,
    this.transactionId,
    this.route,
  });

  final String kind;
  final String? transactionId;
  final String? route;

  String encode() => jsonEncode({
        'kind': kind,
        'transactionId': transactionId,
        'route': route,
      });

  static CaptureNotificationPayload? tryDecode(String? raw) {
    if (raw == null || raw.isEmpty) {
      return null;
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      return null;
    }
    return CaptureNotificationPayload(
      kind: decoded['kind'] as String? ?? '',
      transactionId: decoded['transactionId'] as String?,
      route: decoded['route'] as String?,
    );
  }
}

// Action identifiers — مطابقة للـ iOS category actions.
const String _actionConfirm = 'confirm_tx';
const String _actionDismiss = 'dismiss_tx';
const String _reviewCategoryId = 'review_transaction';

class LocalNotificationService {
  LocalNotificationService._();

  static final LocalNotificationService instance = LocalNotificationService._();
  static const String _reviewChannelId = 'capture_review';
  static const String _lightChannelId = 'capture_light';
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

  Future<String?> initialize() async {
    if (_initialized) {
      final details = await _plugin.getNotificationAppLaunchDetails();
      return _extractTransactionId(details?.notificationResponse?.payload);
    }

    tz.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('Asia/Riyadh'));

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
    required String body,
    required NotificationPreferences preferences,
  }) async {
    if (!preferences.captureReview) {
      return;
    }
    await _show(
      id: transactionId.hashCode,
      title: 'أكّد عملية',
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
          actions: [
            AndroidNotificationAction(_actionConfirm, 'تأكيد ✓'),
            AndroidNotificationAction(_actionDismiss, 'تجاهل',
                cancelNotification: true),
          ],
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: false,
          presentSound: true,
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
  }) async {
    if (!preferences.captureLight) {
      return;
    }
    await _show(
      id: DateTime.now().millisecondsSinceEpoch.remainder(1 << 31),
      title: title,
      body: body,
      notificationType: NotificationType.captureLight,
      preferences: preferences,
      details: const NotificationDetails(
        android: AndroidNotificationDetails(
          _lightChannelId,
          'التقاط العمليات',
          channelDescription: 'إشعارات خفيفة عند التقاط عملية مؤكدة',
          importance: Importance.low,
          priority: Priority.low,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: false,
          presentSound: false,
        ),
      ),
    );
  }

  Future<void> showTestNotification() async {
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
          presentAlert: true,
          presentBadge: false,
          presentSound: true,
        ),
      ),
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
      id: notifId ?? (title.hashCode ^ body.hashCode),
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
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: false,
          presentSound: true,
        ),
      ),
    );
  }

  Future<void> showAchievementNotification({
    required String title,
    required String body,
    required NotificationPreferences preferences,
  }) async {
    await _show(
      id: title.hashCode ^ body.hashCode,
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
          presentAlert: true,
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
    if (!_initialized) {
      await initialize();
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
          presentAlert: true,
          presentBadge: false,
          presentSound: false,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    );
  }

  Future<void> schedulePlannedNotifications(
    List<PlannedLocalNotification> notifications,
  ) async {
    if (!_initialized) {
      await initialize();
    }
    await _plugin.cancel(id: _weeklyReportId);
    final pending = await _plugin.pendingNotificationRequests();
    for (final request in pending) {
      if (request.id >= 92000 && request.id < 992000) {
        await _plugin.cancel(id: request.id);
      }
    }
    for (final notification in notifications) {
      await _plugin.zonedSchedule(
        id: notification.id,
        title: notification.title,
        body: notification.body,
        scheduledDate: _riyadhDate(notification.scheduledAtRiyadh),
        notificationDetails: _detailsFor(notification.kind),
        payload: CaptureNotificationPayload(
          kind: notification.payload ?? notification.kind.name,
          route: _routeFor(notification.payload),
        ).encode(),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      );
    }
  }

  Future<void> showGoalMilestoneNotification({
    required GoalMilestoneNotification notification,
    required NotificationPreferences preferences,
  }) async {
    await _show(
      id: 93000 + notification.goalId.hashCode.abs().remainder(900000),
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
          presentAlert: true,
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
    if (!preferences.isEnabled(notificationType)) {
      return;
    }
    if (!_initialized) {
      await initialize();
    }

    final now = tz.TZDateTime.now(tz.local);
    if (_isQuietHour(now, preferences)) {
      await _plugin.zonedSchedule(
        id: id,
        title: title,
        body: body,
        scheduledDate: _nextAllowedDate(now, preferences),
        notificationDetails: details,
        payload: payload,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      );
      return;
    }

    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: details,
      payload: payload,
    );
  }

  bool _isQuietHour(
    tz.TZDateTime dateTime,
    NotificationPreferences preferences,
  ) {
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

  void _handleNotificationPayload(String? payload, {String? actionId}) {
    final transactionId = _extractTransactionId(payload);
    if (transactionId != null) {
      if (actionId == _actionConfirm) {
        // التطبيق في الـ foreground — نؤكد مباشرة عبر CaptureRuntime.
        CaptureRuntime.instance.requestConfirmation(transactionId);
      } else if (actionId == _actionDismiss) {
        // تجاهل — لا نفتح شيئاً، فقط نحذف العملية المعلّقة في الـ background.
        _runBackgroundAction(transactionId, confirm: false);
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
            presentAlert: true,
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
            presentAlert: true,
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
    final db = await AppDatabase.open();
    try {
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
        await db.customUpdate(
          "DELETE FROM transactions WHERE id = ? AND status = 'pending';",
          variables: [Variable.withString(transactionId)],
        );
      }
    } finally {
      await db.close();
    }
  }
}
