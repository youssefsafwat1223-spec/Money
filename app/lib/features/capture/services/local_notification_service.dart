import 'dart:convert';
import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

import '../../../domain/entities/engagement_entities.dart';
import '../capture_runtime.dart';

class CaptureNotificationPayload {
  const CaptureNotificationPayload({
    required this.kind,
    this.transactionId,
  });

  final String kind;
  final String? transactionId;

  String encode() => jsonEncode({
        'kind': kind,
        'transactionId': transactionId,
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
    );
  }
}

class LocalNotificationService {
  LocalNotificationService._();

  static final LocalNotificationService instance = LocalNotificationService._();
  static const String _reviewChannelId = 'capture_review';
  static const String _lightChannelId = 'capture_light';
  static const String _budgetChannelId = 'budget_alerts';
  static const String _achievementChannelId = 'achievement_alerts';
  static const String _streakChannelId = 'streak_reminders';
  static const int _streakReminderId = 88008;

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
    const darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const windows = WindowsInitializationSettings(
      appName: 'Money Companion',
      appUserModelId: 'MoneyCompanion.App',
      guid: '2a4f4ea2-1d7f-4c7d-9c6f-f0fdf6e44e34',
    );
    const settings = InitializationSettings(
      android: android,
      iOS: darwin,
      macOS: darwin,
      windows: windows,
    );

    await _plugin.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: (response) {
        final transactionId = _extractTransactionId(response.payload);
        if (transactionId != null) {
          CaptureRuntime.instance.requestConfirmation(transactionId);
        }
      },
      onDidReceiveBackgroundNotificationResponse: _backgroundTapHandler,
    );
    _initialized = true;

    final details = await _plugin.getNotificationAppLaunchDetails();
    return _extractTransactionId(details?.notificationResponse?.payload);
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
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: false,
          presentSound: true,
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

  Future<void> showBudgetAlert({
    required String title,
    required String body,
    required NotificationType type,
    required NotificationPreferences preferences,
  }) async {
    await _show(
      id: title.hashCode ^ body.hashCode,
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

  @pragma('vm:entry-point')
  static void _backgroundTapHandler(NotificationResponse response) {}
}
